@kwdef struct Tranparent{T<:Number} <: AbstractFunc
    input_names::Vector{Symbol}
    output_names::Vector{Symbol}
    parameters::ComponentVector{T}
end

function Tranparent(input_names::Vector{Symbol}; parameters::ComponentVector{T}) where {T<:Number}
    Tranparent{T}(input_names=input_names, output_names=input_names, parameters=parameters)
end

function get_output(ele::Tranparent; input::ComponentVector{T}) where {T<:Number}
    input
end