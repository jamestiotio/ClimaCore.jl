module Hypsography

import ..slab, ..column
import ..Geometry,
    ..Domains, ..Topologies, ..Grids, ..Spaces, ..Fields, ..Operators
import ..Spaces: ExtrudedFiniteDifferenceSpace

import ..Grids:
    _ExtrudedFiniteDifferenceGrid,
    ExtrudedFiniteDifferenceGrid,
    HypsographyAdaption,
    Flat

using StaticArrays, LinearAlgebra


"""
    ref_z_to_physical_z(adaption::HypsographyAdaption, z_ref, z_surface, z_top)

Convert reference `z`s to physical `z`s as prescribed by the given adaption.
"""
function ref_z_to_physical_z(
    adaption::HypsographyAdaption,
    z_ref,
    z_surface,
    z_top,
) end

# For no adaption, z_physical is z_ref.
function ref_z_to_physical_z(adaption::Nothing, z_ref, z_surface, z_top)
    return z_ref
end

"""
    _check_adaption_constraints(adaption, z_ref, z_surface, z_top)

Ensures that the `adaption` is well defined for the given parameters.
"""
function _check_adaption_constraints(adaption, z_ref, z_surface, z_top) end

"""
    LinearAdaption(surface::Field)

Locate the levels by linear interpolation between the surface field and the top
of the domain, using the method of [GalChen1975](@cite).
"""
struct LinearAdaption{F <: Union{Fields.Field, Nothing}} <: HypsographyAdaption
    # Union can be removed once deprecation removed.
    surface::F
end

function ref_z_to_physical_z(adaption::LinearAdaption, z_ref, z_surface, z_top)
    return z_ref + (1 - z_ref / z_top) * z_surface
end

"""
    SLEVEAdaption(surface::Field, ηₕ::FT, s::FT)

Locate vertical levels using an exponential function between the surface field and the top
of the domain, using the method of [Schar2002](@cite). This method is modified
such no warping is applied above some user defined parameter 0 ≤ ηₕ < 1.0, where the lower and upper
bounds represent the domain bottom and top respectively. `s` governs the decay rate.
If the decay-scale is poorly specified (i.e., `s * zₜ` is lower than the maximum
surface elevation), a warning is thrown and `s` is adjusted such that it `szₜ > maximum(z_surface)`.
"""
struct SLEVEAdaption{F <: Fields.Field, FT <: Real} <: HypsographyAdaption
    # Union can be removed once deprecation removed.
    surface::F
    ηₕ::FT
    s::FT
end

function _check_adaption_constraints(
    adaption::SLEVEAdaption,
    z_ref,
    z_surface,
    z_top,
)
    ηₕ = adaption.ηₕ
    s = adaption.s
    FT = eltype(s)
    @assert FT(0) <= ηₕ <= FT(1)
    @assert s >= FT(0)
    if s * z_top <= maximum(z_surface)
        @warn "Decay scale (s*z_top = $(s*z_top)) must be higher than max surface elevation (max(z_surface) = $(maximum(z_surface))). Returning s = FT(0.8). Scale height is therefore s=$(0.8 * z_top) m."
    end
end

function ref_z_to_physical_z(adaption::SLEVEAdaption, z_ref, z_surface, z_top)
    ηₕ = adaption.ηₕ
    s = adaption.s
    η = z_ref ./ z_top
    FT = eltype(s)
    # Fix scale height if needed
    s = ifelse(s * z_top <= maximum(z_surface), FT(8 / 10), s)
    return ifelse(
        η <= ηₕ,
        η * z_top + z_surface * (sinh((ηₕ - η) / s / ηₕ)) / (sinh(1 / s)),
        η * z_top,
    )
end

# deprecated in 0.10.12
LinearAdaption() = LinearAdaption(nothing)

@deprecate(
    ExtrudedFiniteDifferenceSpace(
        horizontal_space::Spaces.AbstractSpace,
        vertical_space::Spaces.FiniteDifferenceSpace,
        adaption::LinearAdaption{Nothing},
        z_surface::Fields.Field,
    ),
    ExtrudedFiniteDifferenceSpace(
        horizontal_space,
        vertical_space,
        LinearAdaption(z_surface),
    ),
    false
)

# linear coordinates
function _ExtrudedFiniteDifferenceGrid(
    horizontal_grid::Grids.AbstractGrid,
    vertical_grid::Grids.FiniteDifferenceGrid,
    adaption::HypsographyAdaption,
)
    if adaption isa LinearAdaption
        if isnothing(adaption.surface)
            error("LinearAdaption requires a Field argument")
        end
        if axes(adaption.surface).grid !== horizontal_grid
            error("Terrain must be defined on the horizontal space")
        end
    end

    # construct initial flat space, then mutate
    ref_grid = Grids.ExtrudedFiniteDifferenceGrid(
        horizontal_grid,
        vertical_grid,
        Flat(),
    )
    face_ref_space = Spaces.FaceExtrudedFiniteDifferenceSpace(ref_grid)
    face_ref_coords = Spaces.coordinates_data(face_ref_space)
    coord_type = eltype(face_ref_coords)
    z_ref = face_ref_coords.z

    vertical_domain = Topologies.domain(vertical_grid)
    z_top = vertical_domain.coord_max.z

    grad = Operators.Gradient()
    z_surface = Fields.field_values(adaption.surface)

    FT = eltype(z_surface)

    _check_adaption_constraints(adaption, z_ref, z_surface, z_top)
    fZ_data = ref_z_to_physical_z.(Ref(adaption), z_ref, z_surface, z_top)
    fZ = Fields.Field(fZ_data, face_ref_space)

    # Take the horizontal gradient for the Z surface field
    # for computing updated ∂x∂ξ₃₁, ∂x∂ξ₃₂ terms
    grad = Operators.Gradient()
    If2c = Operators.InterpolateF2C()

    # DSS the horizontal gradient of Z surface field to force
    # deriv continuity along horizontal element boundaries
    f∇Z = grad.(fZ)
    Spaces.weighted_dss!(f∇Z)

    # Interpolate horizontal gradient surface field to centers
    # used to compute ∂x∂ξ₃₃ (Δz) metric term
    cZ = If2c.(fZ)

    # DSS the interpolated horizontal gradients as well
    c∇Z = If2c.(f∇Z)
    Spaces.weighted_dss!(c∇Z)

    face_local_geometry = copy(ref_grid.face_local_geometry)
    center_local_geometry = copy(ref_grid.center_local_geometry)

    Ni, Nj, _, Nv, Nh = size(center_local_geometry)
    for h in 1:Nh, j in 1:Nj, i in 1:Ni
        face_column = column(face_local_geometry, i, j, h)
        fZ_column = column(Fields.field_values(fZ), i, j, h)
        f∇Z_column = column(Fields.field_values(f∇Z), i, j, h)
        center_column = column(center_local_geometry, i, j, h)
        cZ_column = column(Fields.field_values(cZ), i, j, h)
        c∇Z_column = column(Fields.field_values(c∇Z), i, j, h)

        # update face metrics
        for v in 1:(Nv + 1)
            local_geom = face_column[v]
            coord = if coord_type <: Geometry.Abstract2DPoint
                c1 = Geometry.components(local_geom.coordinates)[1]
                coord_type(c1, fZ_column[v])
            elseif coord_type <: Geometry.Abstract3DPoint
                c1 = Geometry.components(local_geom.coordinates)[1]
                c2 = Geometry.components(local_geom.coordinates)[2]
                coord_type(c1, c2, fZ_column[v])
            end
            Δz = if v == 1
                # if this is the domain min face level compute the metric
                # extrapolating from the bottom face level of the domain
                2 * (cZ_column[v] - fZ_column[v])
            elseif v == Nv + 1
                # if this is the domain max face level compute the metric
                # extrapolating from the top face level of the domain
                2 * (fZ_column[v] - cZ_column[v - 1])
            else
                cZ_column[v] - cZ_column[v - 1]
            end
            ∂x∂ξ = reconstruct_metric(local_geom.∂x∂ξ, f∇Z_column[v], Δz)
            W = local_geom.WJ / local_geom.J
            J = det(Geometry.components(∂x∂ξ))
            face_column[v] = Geometry.LocalGeometry(coord, J, W * J, ∂x∂ξ)
        end

        # update center metrics
        for v in 1:Nv
            local_geom = center_column[v]
            coord = if coord_type <: Geometry.Abstract2DPoint
                c1 = Geometry.components(local_geom.coordinates)[1]
                coord_type(c1, cZ_column[v])
            elseif coord_type <: Geometry.Abstract3DPoint
                c1 = Geometry.components(local_geom.coordinates)[1]
                c2 = Geometry.components(local_geom.coordinates)[2]
                coord_type(c1, c2, cZ_column[v])
            end
            Δz = fZ_column[v + 1] - fZ_column[v]
            ∂x∂ξ = reconstruct_metric(local_geom.∂x∂ξ, c∇Z_column[v], Δz)
            W = local_geom.WJ / local_geom.J
            J = det(Geometry.components(∂x∂ξ))
            center_column[v] = Geometry.LocalGeometry(coord, J, W * J, ∂x∂ξ)
        end
    end

    return ExtrudedFiniteDifferenceGrid(
        horizontal_grid,
        vertical_grid,
        adaption,
        ref_grid.global_geometry,
        center_local_geometry,
        face_local_geometry,
    )
end

"""
    diffuse_surface_elevation!(f::Field; κ::T, iter::Int, dt::T)

Option for 2nd order diffusive smoothing of generated terrain.
Mutate (smooth) a given elevation profile `f` before assigning the surface
elevation to the `HypsographyAdaption` type. A spectral second-order diffusion
operator is applied with forward-Euler updates to generate
profiles for each new iteration. Steps to generate smoothed terrain (
represented as a ClimaCore Field) are as follows:
- Compute discrete elevation profile f
- Compute diffuse_surface_elevation!(f, κ, iter). f is mutated.
- Define `Hypsography.LinearAdaption(f)`
- Define `ExtrudedFiniteDifferenceSpace` with new surface elevation.
Default diffusion parameters are appropriate for spherical arrangements.
For `zmax-zsfc` == 𝒪(10^4), κ == 𝒪(10^8), dt == 𝒪(10⁻¹).
"""
function diffuse_surface_elevation!(
    f::Fields.Field;
    κ::T = 1e8,
    maxiter::Int = 100,
    dt::T = 1e-1,
) where {T}
    # Define required ops
    wdiv = Operators.WeakDivergence()
    grad = Operators.Gradient()
    FT = eltype(f)
    # Create dss buffer
    ghost_buffer = (bf = Spaces.create_dss_buffer(f),)
    # Apply smoothing
    for iter in 1:maxiter
        # Euler steps
        χf = @. wdiv(grad(f))
        Spaces.weighted_dss!(χf, ghost_buffer.bf)
        @. f += κ * dt * χf
    end
    # Return mutated surface elevation profile
    return f
end

function reconstruct_metric(
    ∂x∂ξ::Geometry.Axis2Tensor{
        T,
        Tuple{Geometry.UWAxis, Geometry.Covariant13Axis},
    },
    ∇z::Geometry.Covariant1Vector,
    Δz::Real,
) where {T}
    v∂x∂ξ = Geometry.components(∂x∂ξ)
    v∇z = Geometry.components(∇z)
    Geometry.AxisTensor(axes(∂x∂ξ), @SMatrix [
        v∂x∂ξ[1, 1] 0
        v∇z[1] Δz
    ])
end

function reconstruct_metric(
    ∂x∂ξ::Geometry.Axis2Tensor{
        T,
        Tuple{Geometry.UVWAxis, Geometry.Covariant123Axis},
    },
    ∇z::Geometry.Covariant12Vector,
    Δz::Real,
) where {T}
    v∂x∂ξ = Geometry.components(∂x∂ξ)
    v∇z = Geometry.components(∇z)
    Geometry.AxisTensor(
        axes(∂x∂ξ),
        @SMatrix [
            v∂x∂ξ[1, 1] v∂x∂ξ[1, 2] 0
            v∂x∂ξ[2, 1] v∂x∂ξ[2, 2] 0
            v∇z[1] v∇z[2] Δz
        ]
    )
end

end
