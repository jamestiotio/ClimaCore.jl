using Test
using LinearAlgebra

import ClimaCore:
    ClimaCore,
    slab,
    Spaces,
    Domains,
    Meshes,
    Geometry,
    Topologies,
    Spaces,
    Fields,
    Operators
import ClimaCore.Utilities: half

using OrdinaryDiffEq: ODEProblem, solve, SSPRK33

import Logging
import TerminalLoggers
Logging.global_logger(TerminalLoggers.TerminalLogger())

const R = 6.4e6 # radius
const Ω = 7.2921e-5 # Earth rotation (radians / sec)
const z_top = 3.0e4 # height position of the model top
const grav = 9.8 # gravitational constant
const p_0 = 1e5 # mean sea level pressure

const R_d = 287.058 # R dry (gas constant / mol mass dry air)
const T_tri = 273.16 # triple point temperature
const γ = 1.4 # heat capacity ratio
const cv_d = R_d / (γ - 1)

const T_0 = 300 # isothermal atmospheric temperature
const H = R_d * T_0 / grav # scale height

# set up function space
function sphere_3D(
    R = 6.4e6,
    zlim = (0, 30.0e3),
    helem = 4,
    zelem = 15,
    npoly = 5,
)
    FT = Float64
    vertdomain = Domains.IntervalDomain(
        Geometry.ZPoint{FT}(zlim[1]),
        Geometry.ZPoint{FT}(zlim[2]);
        boundary_names = (:bottom, :top),
    )
    vertmesh = Meshes.IntervalMesh(vertdomain, nelems = zelem)
    vert_center_space = Spaces.CenterFiniteDifferenceSpace(vertmesh)

    horzdomain = Domains.SphereDomain(R)
    horzmesh = Meshes.EquiangularCubedSphere(horzdomain, helem)
    horztopology = Topologies.Topology2D(horzmesh)
    quad = Spaces.Quadratures.GLL{npoly + 1}()
    horzspace = Spaces.SpectralElementSpace2D(horztopology, quad)

    hv_center_space =
        Spaces.ExtrudedFiniteDifferenceSpace(horzspace, vert_center_space)
    hv_face_space = Spaces.FaceExtrudedFiniteDifferenceSpace(hv_center_space)
    return (hv_center_space, hv_face_space)
end

# geopotential
Φ(z) = grav * z

# pressure
function pressure(ρ, e, normuvw, z)
    I = e - Φ(z) - normuvw^2 / 2
    T = I / cv_d + T_tri
    return ρ * R_d * T
end

# initial conditions for density and total energy
function init_sbr_thermo(z)

    p = p_0 * exp(-z / H)
    ρ = 1 / R_d / T_0 * p

    T = p / ρ / R_d

    e = cv_d * (T - T_tri) + Φ(z)
    ρe = ρ * e

    return (ρ = ρ, ρe = ρe)
end

function rhs!(dY, Y, _, t)
    cρ = Y.Yc.ρ # density on centers
    fw = Y.w # Covariant3Vector on faces
    cuₕ = Y.uₕ # Covariant12Vector on centers
    cρe = Y.Yc.ρe # total energy on centers

    dρ = dY.Yc.ρ
    dw = dY.w
    duₕ = dY.uₕ
    dρe = dY.Yc.ρe
    z = c_coords.z

    # # 0) update w at the bottom
    # fw = -g^31 cuₕ/ g^33 ????????

    hdiv = Operators.Divergence()
    hwdiv = Operators.Divergence()
    hgrad = Operators.Gradient()
    hwgrad = Operators.Gradient()
    hcurl = Operators.Curl()
    hwcurl = Operators.Curl() # Operator.WeakCurl()

    dρ .= 0 .* cρ
    dw .= 0 .* fw
    duₕ .= 0 .* cuₕ
    dρe .= 0 .* cρe

    # hyperdiffusion not needed in SBR

    # 1) Mass conservation
    If2c = Operators.InterpolateF2C()
    Ic2f = Operators.InterpolateC2F(
        bottom = Operators.Extrapolate(),
        top = Operators.Extrapolate(),
    )
    cw = If2c.(fw)
    cuvw = Geometry.Covariant123Vector.(cuₕ) .+ Geometry.Covariant123Vector.(cw)

    # 1.a) horizontal divergence
    dρ .-= hdiv.(cρ .* (cuvw))

    # 1.b) vertical divergence
    vdivf2c = Operators.DivergenceF2C(
        top = Operators.SetValue(Geometry.Contravariant3Vector(0.0)),
        bottom = Operators.SetValue(Geometry.Contravariant3Vector(0.0)),
    )
    # we want the total u³ at the boundary to be zero: we can either constrain
    # both to be zero, or allow one to be non-zero and set the other to be its
    # negation

    # explicit part
    dρ .-= vdivf2c.(Ic2f.(cρ .* cuₕ))
    # implicit part
    dρ .-= vdivf2c.(Ic2f.(cρ) .* fw)

    # 2) Momentum equation

    # curl term
    # effectively a homogeneous Dirichlet condition on u₁ at the boundary
    vcurlc2f = Operators.CurlC2F(
        bottom = Operators.SetCurl(Geometry.Contravariant12Vector(0.0, 0.0)),
        top = Operators.SetCurl(Geometry.Contravariant12Vector(0.0, 0.0)),
    )
    cω³ = hcurl.(cuₕ) # Contravariant3Vector
    fω¹² = hcurl.(fw) # Contravariant12Vector
    fω¹² .+= vcurlc2f.(cuₕ) # Contravariant12Vector

    # cross product
    # convert to contravariant
    # these will need to be modified with topography
    fu¹² =
        Geometry.Contravariant12Vector.(
            Geometry.Covariant123Vector.(Ic2f.(cuₕ)),
        ) # Contravariant12Vector in 3D
    fu³ = Geometry.Contravariant3Vector.(Geometry.Covariant123Vector.(fw))
    @. dw -= fω¹² × fu¹² # Covariant3Vector on faces
    @. duₕ -= If2c(fω¹² × fu³)

    # Needed for 3D:
    @. duₕ -=
        (f + cω³) ×
        Geometry.Contravariant12Vector(Geometry.Covariant123Vector(cuₕ))

    ce = @. cρe / cρ
    cp = @. pressure(cρ, ce, norm(cuvw), z)

    @. duₕ -= hgrad(cp) / cρ
    vgradc2f = Operators.GradientC2F(
        bottom = Operators.SetGradient(Geometry.Covariant3Vector(0.0)),
        top = Operators.SetGradient(Geometry.Covariant3Vector(0.0)),
    )
    @. dw -= vgradc2f(cp) / Ic2f(cρ)

    cE = @. (norm(cuvw)^2) / 2 + Φ(z)
    @. duₕ -= hgrad(cE)
    @. dw -= vgradc2f(cE)

    # 3) total energy

    @. dρe -= hdiv(cuvw * (cρe + cp))
    @. dρe -= vdivf2c(fw * Ic2f(cρe + cp))
    @. dρe -= vdivf2c(Ic2f(cuₕ * (cρe + cp)))

    Spaces.weighted_dss!(dY.Yc)
    Spaces.weighted_dss!(dY.uₕ)
    Spaces.weighted_dss!(dY.w)

    return dY

end

# set up 3D spherical domain and coords
hv_center_space, hv_face_space = sphere_3D()
c_coords = Fields.coordinate_field(hv_center_space)
f_coords = Fields.coordinate_field(hv_face_space)

# Coriolis
const f = @. Geometry.Contravariant3Vector(
    Geometry.WVector(2 * Ω * sind(c_coords.lat)),
)

# set up initial condition
Yc = map(coord -> init_sbr_thermo(coord.z), c_coords)
uₕ = map(_ -> Geometry.Covariant12Vector(0.0, 0.0), c_coords)
w = map(_ -> Geometry.Covariant3Vector(0.0), f_coords)
Y = Fields.FieldVector(Yc = Yc, uₕ = uₕ, w = w)

# initialize tendency
dYdt = similar(Y)
# set up rhs
rhs!(dYdt, Y, nothing, 0.0)

# run!
using OrdinaryDiffEq
# Solve the ODE
T = 3600
dt = 5
prob = ODEProblem(rhs!, Y, (0.0, T))

haskey(ENV, "CI_PERF_SKIP_RUN") && exit() # for performance analysis

# solve ode
sol = solve(
    prob,
    SSPRK33(),
    dt = dt,
    saveat = dt,
    progress = true,
    adaptive = false,
    progress_message = (dt, u, p, t) -> t,
)

uₕ_phy = Geometry.transform.(Ref(Geometry.UVAxis()), sol.u[end].uₕ)
w_phy = Geometry.transform.(Ref(Geometry.WAxis()), sol.u[end].w)

@test maximum(abs.(uₕ_phy.components.data.:1)) ≤ 1e-11
@test maximum(abs.(uₕ_phy.components.data.:2)) ≤ 1e-11
@test norm(sol.u[end].Yc.ρ) ≈ norm(sol.u[1].Yc.ρ) rtol = 1e-2
@test norm(sol.u[end].Yc.ρe) ≈ norm(sol.u[1].Yc.ρe) rtol = 1e-2
