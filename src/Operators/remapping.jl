using ..Spaces:
    AbstractSpace, SpectralElementSpace1D, SpectralElementSpace2D, Quadratures
using ..Topologies: Topology2D, IntervalTopology
using ..Fields: Field
using ..DataLayouts
using SparseArrays, LinearAlgebra

struct LinearRemap{T <: AbstractSpace, S <: AbstractSpace, M <: AbstractMatrix}
    target::T
    source::S
    map::M # linear mapping operator
end

"""
    LinearRemap(target::AbstractSpace, source::AbstractSpace)

A remapping operator from the `source` space to the `target` space.
"""
function LinearRemap(target::AbstractSpace, source::AbstractSpace)
    R = linear_remap_op(target, source)
    LinearRemap(target, source, R)
end

"""
    remap(R::LinearRemap, source_field::Field)

Applies the remapping operator `R` to `source_field`. Outputs a new field on the target space mapped to by `R`.
"""
function remap(R::LinearRemap, source_field::Field)
    target_space = R.target
    target_field = similar(source_field, target_space, eltype(source_field))
    remap!(target_field, R, source_field)
end

"""
    remap!(target_field::Field, R::LinearRemap, source_field::Field)

Applies the remapping operator `R` to `source_field` and stores the solution in `target_field`.
"""
function remap!(target_field::Field, R::LinearRemap, source_field::Field)
    mul!(vec(parent(target_field)), R.map, vec(parent(source_field)))
    return target_field
end

"""
    linear_remap_op(target::AbstractSpace, source::AbstractSpace)

Computes linear remapping operator `R` for remapping from `source` to `target` spaces.

Entry `R_{ij}` gives the contribution weight to the target node `i` from
source node `j`; nodes are indexed by their global position, determined
by both element index and nodal order within the element.
"""
function linear_remap_op(target::AbstractSpace, source::AbstractSpace)
    J = 1.0 ./ local_weights(target) # workaround for julia #26561
    W = overlap_weights(target, source)
    return W .* J
end

"""
    overlap_weights(target, source)

Computes local weights of the overlap mesh for `source` to `target` spaces.
"""
function overlap_weights(
    target::T,
    source::S,
) where {
    T <: SpectralElementSpace1D{<:IntervalTopology, Quadratures.GL{1}},
    S <: SpectralElementSpace1D{<:IntervalTopology, Quadratures.GL{1}},
}
    # Calculate element overlap pattern
    # X_ov[i,j] = overlap length between target elem i and source elem j
    X_ov = fv_x_overlap(target, source)

    return X_ov
end

function overlap_weights(
    target::T,
    source::S,
) where {
    T <: SpectralElementSpace1D{<:IntervalTopology},
    S <: SpectralElementSpace1D{<:IntervalTopology, Quadratures.GL{1}},
}
    FT = Spaces.undertype(source)
    target_topo = Spaces.topology(target)
    source_topo = Spaces.topology(source)
    nelems_t = Topologies.nlocalelems(target)
    nelems_s = Topologies.nlocalelems(source)
    QS_t = Spaces.quadrature_style(target)
    QS_s = Spaces.quadrature_style(source)
    Nq_t = Quadratures.degrees_of_freedom(QS_t)
    Nq_s = Quadratures.degrees_of_freedom(QS_s)
    J_ov = spzeros(nelems_t * Nq_t, nelems_s * Nq_s)

    # Calculate element overlap pattern
    # X_ov[i,j] = overlap length between target elem i and source elem j
    for i in 1:nelems_t
        vertices_i = Topologies.vertex_coordinates(target_topo, i)
        min_i, max_i = Geometry.component(vertices_i[1], 1),
        Geometry.component(vertices_i[2], 1)
        for j in 1:nelems_s # elems coincide w nodes in FV source
            vertices_j = Topologies.vertex_coordinates(source_topo, j)
            # get interval for quadrature
            min_j, max_j = Geometry.component(vertices_j[1], 1),
            Geometry.component(vertices_j[2], 1)
            min_ov, max_ov = max(min_i, min_j), min(max_i, max_j)
            if max_ov <= min_ov
                continue
            end
            ξ, w = Quadratures.quadrature_points(FT, QS_t)
            x_ov =
                FT(0.5) * (min_ov + max_ov) .+ FT(0.5) * (max_ov - min_ov) * ξ
            x_t = FT(0.5) * (min_i + max_i) .+ FT(0.5) * (max_i - min_i) * ξ

            # column k of I_mat gives the k-th target basis function defined on the overlap element
            I_mat = Quadratures.interpolation_matrix(x_ov, x_t)
            for k in 1:Nq_t
                idx = Nq_t * (i - 1) + k # global nodal index
                # (integral of basis on overlap) / (reference elem length * overlap elem length)
                J_ov[idx, j] = w' * I_mat[:, k] ./ 2 * (max_ov - min_ov)
            end
        end
    end
    return J_ov
end

function overlap_weights(
    target::T,
    source::S,
) where {
    T <: SpectralElementSpace1D{<:IntervalTopology, Quadratures.GL{1}},
    S <: SpectralElementSpace1D{<:IntervalTopology},
}
    J_ov = overlap_weights(source, target)
    return J_ov'
end

function overlap_weights(
    target::T,
    source::S,
) where {
    T <: SpectralElementSpace2D{<:Topology2D, Quadratures.GL{1}},
    S <: SpectralElementSpace2D{<:Topology2D, Quadratures.GL{1}},
}
    # Calculate element overlap pattern in x-dimension
    # X_ov[i,j] = overlap length along x-dimension between target elem i and source elem j
    X_ov = fv_x_overlap(target, source)

    # Calculate element overlap pattern in y-dimension
    Y_ov = fv_y_overlap(target, source)

    return kron(Y_ov, X_ov)
end

function fv_x_overlap(
    target::T,
    source::S,
) where {
    T <: Union{SpectralElementSpace1D, SpectralElementSpace2D},
    S <: Union{SpectralElementSpace1D, SpectralElementSpace2D},
}
    target_topo = Spaces.topology(target)
    source_topo = Spaces.topology(source)
    ntarget, nsource = nxelems(target_topo), nxelems(source_topo)
    v1, v2 = 1, 2

    W_ov = spzeros(ntarget, nsource)
    for i in 1:ntarget
        vertices_i = Topologies.vertex_coordinates(target_topo, i)
        min_i, max_i = xcomponent(vertices_i[v1]), xcomponent(vertices_i[v2])
        for j in 1:nsource
            vertices_j = Topologies.vertex_coordinates(source_topo, j)
            min_j, max_j =
                xcomponent(vertices_j[v1]), xcomponent(vertices_j[v2])
            min_ov, max_ov = max(min_i, min_j), min(max_i, max_j)
            overlap_length = max_ov > min_ov ? max_ov - min_ov : continue
            W_ov[i, j] = overlap_length
        end
    end
    return W_ov
end

function fv_y_overlap(
    target::T,
    source::S,
) where {
    T <: Union{SpectralElementSpace1D, SpectralElementSpace2D},
    S <: Union{SpectralElementSpace1D, SpectralElementSpace2D},
}
    target_topo = Spaces.topology(target)
    source_topo = Spaces.topology(source)
    ntarget, nsource = nyelems(target_topo), nyelems(source_topo)
    nx_target, nx_source = nxelems(target_topo), nxelems(source_topo)
    elem_idx = (i, n) -> 1 + (i - 1) * n
    v1, v2 = 1, 4

    W_ov = spzeros(ntarget, nsource)
    for i in 1:ntarget
        vertices_i =
            Topologies.vertex_coordinates(target_topo, elem_idx(i, nx_target))
        min_i, max_i = ycomponent(vertices_i[v1]), ycomponent(vertices_i[v2])
        for j in 1:nsource
            vertices_j = Topologies.vertex_coordinates(
                source_topo,
                elem_idx(j, nx_source),
            )
            min_j, max_j =
                ycomponent(vertices_j[v1]), ycomponent(vertices_j[v2])
            min_ov, max_ov = max(min_i, min_j), min(max_i, max_j)
            overlap_length = max_ov > min_ov ? max_ov - min_ov : continue
            W_ov[i, j] = overlap_length
        end
    end
    return W_ov
end

nxelems(topology::Topologies.IntervalTopology) =
    Topologies.nlocalelems(topology)
nxelems(topology::Topologies.Topology2D) =
    size(Meshes.elements(topology.mesh), 1)
nyelems(topology::Topologies.Topology2D) =
    size(Meshes.elements(topology.mesh), 1)

xcomponent(x::Geometry.XPoint) = Geometry.component(x, 1)
xcomponent(xy::Geometry.XYPoint) = Geometry.component(xy, 1)
ycomponent(y::Geometry.YPoint) = Geometry.component(y, 1)
ycomponent(xy::Geometry.XYPoint) = Geometry.component(xy, 2)

"""
    local_weights(space::AbstractSpace)

Each degree of freedom is associated with a local weight J_i.
For finite volumes the local weight J_i would represent the geometric area
of the associated region. For nodal finite elements, the local weight
represents the value of the global Jacobian, or some global integral of the
associated basis function.
"""
function local_weights(space::AbstractSpace)
    wj = space.local_geometry.WJ
    return vec(parent(wj))
end

slab_value(data::DataLayouts.IJFH, i) = slab(data, i)[1, 1]
slab_value(data::DataLayouts.IFH, i) = slab(data, i)[1]
