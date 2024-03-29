function SnowfallFlux(input_names::Union{Vector{Symbol},Dict{Symbol,Symbol}},
    output_names::Symbol=:snowfall;
    param_names::Vector{Symbol}=Symbol[])
    
    SimpleFlux(
        input_names,
        output_names,
        param_names=param_names,
        func=snowfall_func
    )
end

function snowfall_func(
    i::namedtuple(:prcp, :temp),
    p::namedtuple(:Tmin),
    sf::Function
)
    @.(sf(p[:Tmin] - i[:temp]) * i[:prcp])
end

function snowfall_func(
    i::namedtuple(:prcp, :temp),
    p::namedtuple(:tt, :tti),
    sf::Function
)
    tmp_t1 = p[:tt] - 0.5 * p[:tti]
    tmp_t2 = p[:tt] + 0.5 * p[:tti]
    @.(sf(tmp_t1 - i[:temp]) * i[:prcp] +
    sf(tmp_t2 - i[:temp]) * sf(i[:temp] - tmp_t1) * i[:prcp] * (tmp_t2 - i[:temp]) / p[:tti])
end
