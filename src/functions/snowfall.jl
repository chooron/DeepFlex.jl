function Snowfall(input_names::Vector{Symbol}; parameters::Union{ComponentVector{T},Nothing}=nothing) where {T<:Number}
    build_flux(
        input_names,
        [:Snowfall],
        parameters,
        snowfall_func
    )
end

function snowfall_func(
    input::gen_namedtuple_type([:Prcp,:Temp], T),
    parameters::gen_namedtuple_type([:Tmin], T)
)::gen_namedtuple_type([:Snowfall], T) where {T<:Number}
    (Snowfall=@.(step_func(parameters[:Tmin] - input[:Temp]) * input[:Prcp]),)
end
