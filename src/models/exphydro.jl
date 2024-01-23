@kwdef mutable struct InterceptionFilter{T<:Number} <: ParameterizedElement
    id::String
    Tmin::T

    num_upstream::Int = 1
    num_downstream::Int = 1
    param_names::Vector{Symbol} = [:Tmin]
    input_names::Vector{Symbol} = [:Prcp, :Temp]
    output_names::Vector{Symbol} = [:Snow, :Rain]
end

function InterceptionFilter(; id::String, parameters::Dict{Symbol,T}) where {T<:Number}
    InterceptionFilter{T}(id=id, Tmin=get(parameters, :Tmin, 0.0))
end

function get_fluxes(ele::InterceptionFilter; input::Dict{Symbol,Vector{T}}, solve::Bool=true)::Dict{Symbol,Vector{T}} where {T<:Number}
    flux_snow = snowfall.(input[:Prcp], input[:Temp], ele.Tmin)
    flux_rain = rainfall.(input[:Prcp], input[:Temp], ele.Tmin)
    return Dict(:Snow => flux_snow, :Rain => flux_rain)
end

@kwdef mutable struct SnowReservoir{T<:Number} <: ODEsElement
    id::String

    # parameters
    Tmax::T
    Df::T

    # states
    SnowWater::T
    states::Dict{Symbol,Vector{T}} =Dict{Symbol,Vector{T}}()

    # solver
    solver::Any

    # attribute
    num_upstream::Int = 1
    num_downstream::Int = 1
    param_names::Vector{Symbol} = [:Tmax, :Df]
    state_names::Vector{Symbol} = [:SnowWater]
    input_names::Vector{Symbol} = [:Snow, :Temp]
    output_names::Vector{Symbol} = [:Melt]
end

function SnowReservoir(; id::String, parameters::Dict{Symbol,T}, init_states::Dict{Symbol,T}, solver::Any) where {T<:Number}
    SnowReservoir{T}(id=id,
        Tmax=get(parameters, :Tmax, 1.0),
        Df=get(parameters, :Df, 1.0),
        SnowWater=get(init_states, :SnowWater, 0.0),
        solver=solver)
end

function get_du(ele::SnowReservoir{T}; S::Vector{T}, input::Dict{Symbol,T}) where {T<:Number}
    return get(input, :Snow, 0.0) .- melt.(S, input[:Temp], ele.Tmax, ele.Df)
end

function get_fluxes(ele::SnowReservoir{T}; S::Matrix{T}, input::Dict{Symbol,Vector{T}}) where {T<:Number}
    return Dict(:Melt => melt.(S[1, :], input[:Temp], ele.Tmax, ele.Df))
end


@kwdef mutable struct SoilWaterReservoir{T<:Number} <: ODEsElement
    id::String

    # parameters
    Smax::T
    Qmax::T
    f::T

    # states
    SoilWater::T
    states::Dict{Symbol,Vector{T}} =Dict{Symbol,Vector{T}}()

    # solver
    solver::Any

    # attribute
    num_upstream::Int = 1
    num_downstream::Int = 1
    param_names::Vector{Symbol} = [:Smax, :Qmax, :f]
    state_names::Vector{Symbol} = [:SoilWater]
    input_names::Vector{Symbol} = [:Rain, :Melt, :Temp, :Lday]
    output_names::Vector{Symbol} = [:Pet, :Et, :Qb, :Qs]

end

function SoilWaterReservoir(; id::String, parameters::Dict{Symbol,T}, init_states::Dict{Symbol,T}, solver::Any) where {T<:Number}
    SoilWaterReservoir{T}(id=id,
        Smax=get(parameters, :Smax, 1.0),
        Qmax=get(parameters, :Qmax, 0.0),
        f=get(parameters, :f, 0.0),
        SoilWater=get(init_states, :SoilWater, 10.0),
        solver=solver)
end

function get_du(ele::SoilWaterReservoir{T}; S::Vector{T}, input::Dict{Symbol,T}) where {T<:Number}
    flux_rain = input[:Rain]
    flux_melt = input[:Melt]

    flux_pet = pet.(input[:Temp], input[:Lday])
    flux_et = evap.(S, flux_pet, ele.Smax)
    flux_qb = baseflow.(S, ele.Smax, ele.Qmax, ele.f)
    flux_qs = surfaceflow.(S, ele.Smax)

    du = @.(flux_rain + flux_melt - flux_et - flux_qb - flux_qs)
    return du
end

function get_fluxes(ele::SoilWaterReservoir{T}; S::Matrix{T}, input::Dict{Symbol,Vector{T}}) where {T<:Number}
    soilwater = S[1, :]
    flux_pet = pet.(input[:Temp], input[:Lday])
    flux_et = evap.(soilwater, flux_pet, ele.Smax)
    flux_qb = baseflow.(soilwater, ele.Smax, ele.Qmax, ele.f)
    flux_qs = surfaceflow.(soilwater, ele.Smax)
    return Dict(:Pet => flux_pet, :Et => flux_et, :Qb => flux_qb, :Qs => flux_qs)
end

@kwdef struct FluxAggregator <: BaseElement
    id::String

    num_upstream::Int = 1
    num_downstream::Int = 1
    input_names::Vector{Symbol} = [:Qb, :Qs]
    output_names::Vector{Symbol} = [:Q]
end

function get_fluxes(ele::FluxAggregator; input::Dict{Symbol,Vector{T}}) where {T<:Number}
    flux_q = input[:Qb] + input[:Qs]
    return Dict(:Q => flux_q)
end

@kwdef mutable struct ExpHydro{T} <: Unit where {T<:Number}
    id::String

    # model structure
    structure::AbstractGraph

    # inner variables
    fluxes::Dict{Symbol,Vector{T}} = Dict()

    # attribute
    param_names::Vector{Symbol} = [:Tmin, :Tmax, :Df, :Smax, :Qmax, :f]
    input_names::Vector{Symbol} = [:Prcp, :Temp, :Lday]
    output_names::Vector{Symbol} = [:Q]
end

function ExpHydro(; id::String, parameters::Dict{Symbol,T}, init_states::Dict{Symbol,T}) where {T<:Number}

    dag = SimpleDiGraph(4)
    add_edge!(dag, 1, 2)
    add_edge!(dag, 2, 3)
    add_edge!(dag, 3, 4)

    structure = MetaDiGraph(dag)
    set_props!(structure, 1, Dict(:ele => InterceptionFilter(id="ir", parameters=parameters)))
    set_props!(structure, 2, Dict(:ele => SnowReservoir(id="sr", parameters=parameters, init_states=init_states, solver=nothing)))
    set_props!(structure, 3, Dict(:ele => SoilWaterReservoir(id="wr", parameters=parameters, init_states=init_states, solver=nothing)))
    set_props!(structure, 4, Dict(:ele => FluxAggregator(id="fa")))

    ExpHydro{T}(id=id, structure=structure)
end
