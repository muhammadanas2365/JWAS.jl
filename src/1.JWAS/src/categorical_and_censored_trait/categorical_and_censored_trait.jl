################################################################################
# Categorial and censored traits
#1)Sorensen and Gianola, Likelihood, Bayesian, and MCMC Methods in Quantitative
#Genetics
#2)Wang, Chonglong, et al. Bayesian methods for jointly estimating genomic
#breeding values of one continuous and one threshold trait. Plos one 12.4 (2017)
#3)Wang et al.(2013). Bayesian methods for estimating GEBVs of threshold traits.
#Heredity, 110(3), 213–219.
################################################################################
function categorical_censored_traits_setup!(mme,df)
    nInd                    = length(mme.obsID)
    nTrait                  = mme.nModels
    categorical_trait_index = findall(x -> x=="categorical", mme.traits_type)
    censored_trait_index    = findall(x -> x=="censored",    mme.traits_type)
    censored_categorical_trait_index = [censored_trait_index ; categorical_trait_index]
    n_categorical_trait     = length(categorical_trait_index)
    n_censored_trait        = length(censored_trait_index)
    is_multi_trait          = nTrait>1
    R                       = mme.R

    starting_value = mme.sol
    cmean          = mme.X*starting_value[1:size(mme.mmeLhs,1)] #maker effects defaulting to all zeros
    cmean          = reshape(cmean,nInd,nTrait)

    ySparse      = reshape(mme.ySparse,nInd,nTrait) #mme.ySparse will also change since reshape is a reference, not copy

    ############################################################################
    # setup upper and lower bounds
    ############################################################################
    upper_bound = Array{Float64}(undef, nInd, nTrait)
    lower_bound = Array{Float64}(undef, nInd, nTrait)
    thresholds_all = Array{Array{Float64},1}(undef,n_categorical_trait) #each element is the threshold for a categorical trait
    category_obs = map(Int,ySparse[:,categorical_trait_index])

    #### categorical traits
    if n_categorical_trait != 0
        ncategories  = [length(unique(col)) for col in eachcol(category_obs)]
        # initialize threshold for each categorical trait
        for t in 1:n_categorical_trait
            trait_index = categorical_trait_index[t]
            μ           = mean(cmean[:,trait_index])
            σ           = R[trait_index,trait_index]
            tmin, tmax  = μ-10σ, μ+10σ
            if ncategories[t] == 2 #binary trait
                 thresholds_all[t] = [tmin, 0, tmax]
            else
                if !is_multi_trait #t_min=μ-10σ < t1=0 < t2 <...< t_{#category-1} < t_max=μ+10σ, where t_{#c-1}<1
                    thresholds_all[t] = [tmin;range(0, length=ncategories[t],stop=1)[1:(end-1)];tmax]
                else               #t_min=μ-10σ < t1=0 < t2=1 < t3 <...< t_{#category-1} < t_max=μ+10σ
                    thresholds_all[t] = [tmin; 0; range(1,length=ncategories[t]-1,stop=tmax)]
                end
            end
            # check whether the categories are 1,2,3...; otherwise it will cause indexing error
            category_obs_t     = category_obs[:,t]
            user_categories    = sort(unique(category_obs_t))
            correct_categories = collect(1:ncategories[t])
            if user_categories != correct_categories
                trait_name = mme.lhsVec[trait_index]
                error("For categorical trait $trait_name, the categories should be ",correct_categories," ; instead of ",user_categories)
            end
        end
        # update lower_bound and upper_bound
        update_bounds_from_threshold!(lower_bound,upper_bound,category_obs,thresholds_all,categorical_trait_index)
    end

    #### cesored traits
    if n_censored_trait != 0
        lower_bound[:,censored_trait_index]  = Matrix(df[!,Symbol.(mme.lhsVec[censored_trait_index],"_l")])
        upper_bound[:,censored_trait_index]  = Matrix(df[!,Symbol.(mme.lhsVec[censored_trait_index],"_u")])
    end

    ############################################################################
    # set up liability (update mme.ySparse)
    ############################################################################
    for t in censored_categorical_trait_index
        for i in 1:nInd
            if lower_bound[i,t] != upper_bound[i,t]
                ySparse[i,t] = rand(truncated(Normal(cmean[i,t], sqrt(R[t,t])), lower_bound[i,t], upper_bound[i,t])) #mme.R has been fixed to 1.0 for category single-trait analysis
            else
                ySparse[i,t] = lower_bound[i,t]
            end
        end
    end

    ySparse = reshape(ySparse,nInd*nTrait,1)

    return category_obs,thresholds_all,lower_bound,upper_bound
end


function categorical_trait_sample_threshold(mme, thresholds_all, category_obs)
    ########################################################################
    # Thresholds for categorical trait
    ########################################################################
    # single-trait:
    #   t_min=μ-10σ < t1=0 < t2 < ... < t_{categories-1} < t_max=μ+10σ
    # multi-trait:
    #   t_min=μ-10σ < t1=0 < t2=1 < t3 < ... < t_{#category-1} < t_max=μ+10σ
    nInd                    = length(mme.obsID)
    nTrait                  = mme.nModels
    categorical_trait_index = findall(x -> x=="categorical", mme.traits_type)
    start_index             = nTrait>1 ? 4 : 3  #some thresholds were fixed
    ySparse                 = reshape(mme.ySparse, nInd, nTrait)

    for t in 1:length(categorical_trait_index)
        thresholds = thresholds_all[t]
        categorical_trait = categorical_trait_index[t]
        for i in start_index:(length(thresholds)-1) #e.g., t2 between categories 2 and 3
            lowerboundry  = maximum(ySparse[:,categorical_trait][category_obs[:,t].==(i-1)])
            upperboundry  = minimum(ySparse[:,categorical_trait][category_obs[:,t].== i])
            thresholds[i] = rand(Uniform(lowerboundry,upperboundry))
        end
        thresholds_all[t]=thresholds
    end
    return thresholds_all
end


function sample_liabilities!(mme,ycorr,lower_bound,upper_bound;nGibbs=5)
    ############################################################################
    # update mme.ySparse (i.e., liability) and ycorr for censored and categorical traits
    ############################################################################
    cmean = mme.ySparse - ycorr
    nInd           = length(mme.obsID)
    nTrait         = mme.nModels
    is_multi_trait = nTrait>1
    R              = mme.R
    cmean          = reshape(cmean,      nInd,nTrait)
    ySparse        = reshape(mme.ySparse,nInd,nTrait) #mme.ySparse will also be updated since reshape is a reference, not copy
    ycorr          = reshape(ycorr,      nInd,nTrait) #ycorr will be updated since reshape is a reference, not copy

    for iter in 1:nGibbs
        for t in 1:nTrait
            if mme.traits_type[t] ∈ ["categorical","censored"]
                index1 = t  # "1" denotes the trait for sampling liability, "2" denotes all other traits.
                index2 = deleteat!(collect(1:nTrait),index1)
                d      = ySparse[:,index2]-cmean[:,index2] #current residuals for all other traits (d)
                #sample residual trait "1"
                μ_1    = is_multi_trait ? vec(R[index1,index2]'inv(R[index2,index2])*d') : zeros(nInd)
                σ2_1   = is_multi_trait ? R[index1,index1]-R[index1,index2]'inv(R[index2,index2])*R[index2,index1] : R #R=1 for single categorical trait
                ϵ1_lower_bound = lower_bound[:,t] - cmean[:,index1] #thresholds[t][whichcategory] - cmean[:,index1]
                ϵ1_upper_bound = upper_bound[:,t] - cmean[:,index1] #thresholds[t][whichcategory+1] - cmean[:,index1]
                for i in 1:nInd
                    if ϵ1_lower_bound[i] != ϵ1_upper_bound[i]
                        ϵ1                = rand(truncated(Normal(μ_1[i], sqrt(σ2_1)), ϵ1_lower_bound[i], ϵ1_upper_bound[i]))
                        ySparse[i,index1] = cmean[i,index1] + ϵ1
                        ycorr[i,index1]   = ϵ1
                    end
                end
            end
        end
    end
    ySparse = reshape(ySparse,nInd*nTrait,1)
    ycorr=vec(ycorr)
end


function update_bounds_from_threshold!(lower_bound,upper_bound,category_obs,thresholds_all,categorical_trait_index)
    ############################################################################
    # update lower_bound, upper_bound from thresholds
    ############################################################################
    for t in 1:length(thresholds_all) # number of categorical_trait
        trait_index   = categorical_trait_index[t]
        whichcategory = category_obs[:,t]
        lower_bound[:,trait_index] = thresholds_all[t][whichcategory]
        upper_bound[:,trait_index] = thresholds_all[t][whichcategory.+1]
    end
end


# print an example for deprecated JWAS function runMCMC(categorical_trait,censored_trait)
function print_single_categorical_censored_trait_example()
    @error("The arguments 'categorical_trait' and  'censored_trait' has been moved to build_model(). Please check our latest example.")
    printstyled("1. Example to build model for single categorical trait:\n"; color=:red)
    printstyled("      model_equation  = \"y = intercept + x1 + x2 + x2*x3 + ID + dam + genotypes\"
      model = build_model(model_equation,categorical_trait=[\"y\"])\n"; color=:red)
    printstyled("2. Example to build model for single censored trait:\n"; color=:red)
    printstyled("      model_equation  = \"y = intercept + x1 + x2 + x2*x3 + ID + dam + genotypes\"
      model = build_model(model_equation,censored_trait=[\"y\"])\n"; color=:red)
end
