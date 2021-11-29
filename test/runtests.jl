using Base: operator_associativity


# Order of tests is intended to reflect dependency order of functionality
include("recursive.jl")
include("data1d.jl")
include("data2d.jl")
include("data1dx.jl")
include("data2dx.jl")
include("geometry.jl")
include("axistensors.jl")
include("grid.jl")
include("grid2d.jl")
include("grid2d_cs.jl")
include("quadrature.jl")
include("spaces.jl")
include("field.jl")
include("spectraloperators.jl")
include("spectralspaces_opt.jl")
include("diffusion2d.jl")
include("fdspaces.jl")
include("fdspaces_opt.jl")
include("fielddiffeq.jl")
include("hybrid2d.jl")
include("hybrid3d.jl")
include("remapping.jl")
include("cubed_spheres.jl")
include("sphere_geometry.jl")
include("sphere_metric_terms.jl")
include("sphere_gradient.jl")
include("sphere_divergence.jl")
include("sphere_curl.jl")
include("sphere_diffusion.jl")
include("sphere_hyperdiffusion.jl")

if "CUDA" in ARGS
    include("gpu/cuda.jl")
    include("gpu/data.jl")
end
