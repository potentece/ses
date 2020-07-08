abbreviations =
  tribble(
    ~shorthand,  ~meaning,                
    "ttT", "DE: ranked genes",
    "tfbm", "TFBM: uncorrected p-values",
    "m1", "multivariate outcome = set of individual genes",       
    "m2", "univariate outcome (median + Yeo-Johnson)",
    "m3", "univariate outcome (mean)",
    "m4", "multivariate permutation (c.f. m1)",
    "m5", "multiple testing",
    "m6", "multivariate outcome = top rotated PCs in signature set",
    "m7", "regress rotated PCs on covariates, one by one (see m6 for complementary analysis)",
    
    "m98", "regress PCs on covariates",
    "m99", "mediation (outcome = mean mRNA)"
  )

fit_m1 = function(datt, gene_set){ 
  # workhorse
  (rec = 
     str_c(gene_set, collapse = " + ") %>% 
     str_c(" ~ .") %>% 
     as.formula() %>% 
     recipe(datt) %>% 
     step_YeoJohnson(all_outcomes()))
  (mod = linear_reg() %>% 
      set_engine("lm"))
  (wf = 
      workflow() %>% 
      add_recipe(rec) %>% 
      add_model(mod) %>% 
      fit(datt))
  
  
  aa = pluck(wf, "fit", "fit", "fit")
  
  
  ############################################################
  # POSSIBLE DIAGNOSTICS
  ############################################################
  
  # bookkeeping: because lm implicitly drops NA
  ok = complete.cases(datt) # missing data for some phenotype dimensions (all genotype data non-missing)  
  
  if(diagnose <- FALSE){  
    
    
    responses = aa$model[[1]] %>%
      as_tibble()
    par(mfrow = c(1,1))
    psych::outlier(responses) # same, but flipped axes
    par(mfrow = c(5,6))
    responses  %>% split(dat$Plate[ok]) %>% imap(safely(~psych::outlier(.x, xlab = .y)))
    
    responses  %>% split(dat$Plate[ok]) %>% map(MVN::mvn) %>% map("multivariateNormality")
    responses  %>% split(dat$Plate[ok]) %>% map(MVN::mvn)  %>% map("univariateNormality") %>% map_df(~table(.x$Normality)) # which are univariate normal
    
  }
  
  # Mahalanobis Distance (MD) calculates the distance of each case from the
  # central mean. Larger values indicate that a case is farther from where most
  # of the points cluster
  
  ############################################################
  # outliers
  ############################################################
  
  if(remove_outliers <-FALSE){ 
    
    # Use mahalobis distance, but fallability of MD, which Leys et al. (2018)
    # argue is not a robust way to determine outliers. The problem lies with the
    # fact that MD uses the means and covariances of all the data – including the
    # outliers – and bases the individual difference scores from these values.
    # Solution: calculate covariance using a subset of the data that is the most
    # central. This is the idea behind Minimum Covariance Determinant, which
    # calculates the mean and covariance matrix based on the most central subset
    # of the data.
    library(MASS)
    alpha <- .001
    cutoff <- (qchisq(p = 1 - alpha, df = ncol(responses)))
    output75 <- cov.mcd(responses, quantile.used = nrow(responses)*.75)
    mhmcd75 <- mahalanobis(responses, output75$center, output75$cov)
    outlier = mhmcd75 > cutoff
    data_clean_mcd <- responses[!outlier, ]
    par(mfrow = c(5,6))
    data_clean_mcd  %>% split(dat$Plate[ok][!outlier]) %>% imap(safely(~psych::outlier(.x, xlab = .y)))
    
    data_clean_mcd  %>% 
      split(dat$Plate[ok][!outlier]) %>% 
      imap(safely(~psych::outlier(.x, xlab = .y))) %>% 
      map("error") %>% 
      keep(compose(`!`, is.null))
    
    # more formal test of outliers by using a cut-off score for MD. Here, I’ll
    # recalcuate the MDs using the mahalanobis function and identify those that
    # fall above the cut-off score for a chi-square with k degrees of freedom
    
    md <- mahalanobis(responses, center = colMeans(responses), cov = cov(responses))
    
    
    names_outliers_MH <- which(md > cutoff)
    
    excluded_mh <- names_outliers_MH
    
    data_clean_mh <- responses[-excluded_mh, ]
    
    responses[excluded_mh, ]
    
    responses
    MVN::mvn(responses, univariatePlot = "qq")
    
    
    print(responses)
  }
  aa
}


fit_m2 = function(datt, gene_set){ 
  # workhorse
  
  # ONLY BINDING LOCALLY :+)
  datt = bind_cols(select(datt, -gene_set),
                   gene_set = apply(datt[gene_set], 1, median)) 
  gene_set = "gene_set"
  (rec = 
      str_c(gene_set) %>% 
      str_c(" ~ .") %>% 
      as.formula() %>% 
      recipe(datt) %>% 
      step_YeoJohnson(all_outcomes()))
  (mod = linear_reg() %>% 
      set_engine("lm"))
  (wf = 
      workflow() %>% 
      add_recipe(rec) %>% 
      add_model(mod) %>% 
      fit(datt))
  out = pluck(wf, "fit", "fit", "fit")
  
  # par(mfrow = c(2,2))
  # plot(out)
  # title(main = "median + Yeo")
  
  out
}

fit_m3 = function(datt, gene_set){  
  
  datt = bind_cols(select(datt, -gene_set),
                   gene_set = apply(datt[gene_set], 1, mean)) 
  gene_set = "gene_set"
  (rec = 
      str_c(gene_set) %>% 
      str_c(" ~ .") %>% 
      as.formula() %>% 
      recipe(datt))
  (mod = linear_reg() %>% 
      set_engine("lm"))
  (wf = 
      workflow() %>% 
      add_recipe(rec) %>% 
      add_model(mod) %>% 
      fit(datt))
  out =   pluck(wf, "fit", "fit", "fit") 
  
  # par(mfrow = c(2,2))
  # plot(out)
  # title(main = "mean")
  
  out
}


fit_m4 = function(datt, gene_set, n_perm, out = NULL){
  
  # function to permute ses_sss_composite
  perm = 
    as_mapper(
      ~mutate(.x, treatment = treatment[sample(dim(.x)[1])])
    ) 
  get_teststat = 
    as_mapper(
      ~ capture.output(car::Manova(.x))  %>% 
        str_subset("treatment") %>% 
        str_split(" ", simplify = TRUE) %>% 
        str_subset("[0-9]") %>%
        pluck(2) %>% 
        as.numeric()
    )
  
  # NOTE THIS EXCLUDES BAD GENES: setdiff(gene_set, bad_residuals)
  set.seed(123)
  out$permutation_statistics = 
    tibble(samps = rerun(n_perm, perm(datt))) %>% 
    mutate(mods = map(samps, ~ fit_m1(.x, gene_set = gene_set)),
           teststat = map_dbl(mods, possibly(get_teststat, otherwise = NULL)))
  
  out$unpermuted_teststat = get_teststat(fit_m1(datt, gene_set))
  
  fig = 
    out$permutation_statistics %>%
    ggformula::gf_histogram(~teststat) %>% 
    ggformula::gf_labs(title = gene_set_name) +
    geom_vline(xintercept = out$unpermuted_teststat)
  
  return(out = out)
}

fit_m5 = function(controls, treatment, gene_set){
  
  # Specify whole-genome regression of rna on design
  y <- dat[gene_set] %>% Biobase::exprs()
  X <- dat %>% Biobase::pData() %>% select(all_of(controls), all_of(treatment))
  
  keep = X %>% complete.cases()
  X = X[keep, ]
  y = y[, keep]
  
  if(sanity <- FALSE) a = gene_set %>% set_names %>% map(~lm(lm(y[.x,] ~ ., data =  X)))  %>% map(anova) %>% map(tidy) %>% map(filter, term == treatment) %>% map_dbl(pluck, "p.value")
  
  X = model.matrix(~ ., data = X)
  
  # Estimate DE using standard limmma/edger pipeline. 
  # but.. first redefine treatment because limma::topTable is awkward about factors
  treatment = X %>% colnames() %>% str_detect(treatment) %>% which()
  ttT <-
    lmFit(y, X) %>%
    eBayes %>%
    tidy_topTable(of_in = treatment)
  
  if(sanity){ 
    b = ttT$P.Value %>% set_names(ttT$gene)  
    plot(b, a[names(b)])
  }
  
  ttT
}





############################################################
#  PCA: m6, m7
############################################################

fit_pca_util = function(datt, gene_set, rotate, ncomp = 9){
  # ncomp chosen to be smaller than the smallest gene set: kidney_transplant_tolerance_mRNA with 9 elements
  pca_rotated <- psych::principal(datt[gene_set], 
                                  rotate = rotate,
                                  nfactors = ncomp, 
                                  scores = TRUE)
  
  pca_rotated$scores = pca_rotated$scores %>%  as_tibble() %>%  set_names(str_c("d", 1:9))
  print(mean(pca_rotated$communality))
  plot(pca_rotated$values)
  pca_rotated
}

fit_m6 = function(datt, gene_set, rotate){
  
  pca_rotated = fit_pca_util(datt, gene_set, rotate)
  datt =   datt %>% select(-gene_set) %>% bind_cols(pca_rotated$scores) # replace genes with the rotated scores
  gene_set = colnames(pca_rotated$scores)
  
  # workhorse
  (rec = 
      str_c(gene_set, collapse = " + ") %>% 
      str_c(" ~ .") %>% 
      as.formula() %>% 
      recipe(datt) %>% 
      step_YeoJohnson(all_outcomes()))
  (mod = linear_reg() %>% 
      set_engine("lm"))
  (wf = 
      workflow() %>% 
      add_recipe(rec) %>% 
      add_model(mod) %>% 
      fit(datt))
  
  # print(pca_rotated$loadings)
  pluck(wf, "fit", "fit", "fit")
  
}


fit_m7 = function(datt, gene_set, rotate){
  
  pca_rotated = fit_pca_util(datt, gene_set, rotate) 
  datt = dplyr::select(datt, -gene_set) 
  gene_set = colnames(pca_rotated$scores)
  
  workflow_reg = 
    function(outcome, datt){
      
      datt_pca = bind_cols(datt, !!outcome := pca_rotated$scores[, outcome])
      
      (rec =
          str_c(outcome) %>%
          str_c(" ~ .") %>%
          as.formula() %>%
          recipe(datt_pca))
      (mod = linear_reg() %>%
          set_engine("lm"))
      (wf =
          workflow() %>%
          add_recipe(rec) %>%
          add_model(mod) %>%
          fit(datt_pca))
    }
  
  gene_set %>% 
    set_names() %>% 
    map(workflow_reg, datt = datt) %>% 
    map(~ pluck(.x, "fit", "fit", "fit"))
  
}

############################################################
# WENJIA'S PCA
############################################################

fit_m98 = function(datt, gene_set){
  # workhorse
  
  # ONLY BINDING LOCALLY :+)
  signature_pca = 
    datt[gene_set] %>% 
    prcomp(scale. = TRUE) %>%  
    factoextra::get_pca_ind() %>%
    pluck("coord") %>%
    as.data.frame()
  
  datt = bind_cols(dplyr::select(datt, -gene_set), signature_pca)
  gene_set = colnames(datt) %>% str_subset("Dim")
  
  workflow_reg = 
    function(outcome, datt){
      
      datt_pca = bind_cols(dplyr::select(datt, -matches("Dim")),
                           dplyr::select(datt, outcome))
      
      (rec =
          str_c(outcome) %>%
          str_c(" ~ .") %>%
          as.formula() %>%
          recipe(datt_pca))
      (mod = linear_reg() %>%
          set_engine("lm"))
      (wf =
          workflow() %>%
          add_recipe(rec) %>%
          add_model(mod) %>%
          fit(datt_pca))
    }
  
  out_all = gene_set %>% set_names() %>% map(workflow_reg, datt = datt) 
  map(out_all, ~ pluck(.x, "fit", "fit", "fit"))
  
}

############################################################
# MEDIATION
############################################################

fit_m99 = function(datt, gene_set){
  
  datt = bind_cols(dplyr::select(datt, -gene_set),
                   gene_set = apply(datt[gene_set], 1, mean))
  gene_set = "gene_set"
  
  if (is.numeric(datt$mediator)){
    
    # gene_set outcome is dependent measure
    (rec =
       str_c(gene_set) %>%
       str_c(" ~ .") %>%
       as.formula() %>%
       recipe(datt))
    (mod = linear_reg() %>%
        set_engine("lm"))
    (wf =
        workflow() %>%
        add_recipe(rec) %>%
        add_model(mod) %>%
        fit(datt))
    out.y = pluck(wf, "fit", "fit", "fit")
    
    # mediate is dependent measure    
    (rec =
        str_c("mediator") %>%
        str_c(" ~ .") %>%
        as.formula() %>%
        recipe(datt %>% dplyr::select(-gene_set)))
    
    (mod = linear_reg() %>%
        set_engine("lm"))
    
    (wf =
        workflow() %>%
        add_recipe(rec) %>%
        add_model(mod) %>%
        fit(datt %>% dplyr::select(-gene_set)))
    
    out.m = pluck(wf, "fit", "fit", "fit")
    
  }else if(datt$mediator %>% table() %>% length()==2){
    datt$mediator = datt$mediator %>% as.character() %>%  as.numeric()
    keep = datt %>% complete.cases()
    datt_keep = datt[keep,]
    
    formula_y = str_c("gene_set", " ~ .") %>% as.formula()
    out.y = lm(formula_y, data = datt_keep)
    
    formula_m = str_c("mediator", " ~ .") %>% as.formula()
    out.m = glm(formula_m, family = "binomial", data = datt_keep %>% dplyr::select(-gene_set))
  }else if(datt$mediator %>% table() %>% length()>2){
    datt$mediator = datt$mediator %>% as.factor()
    keep = datt %>% complete.cases()
    datt_keep = datt[keep,]
    
    formula_y = str_c("gene_set", " ~ .") %>% as.formula()
    out.y = lm(formula_y, data = datt_keep)
    # has met some numerical problem with the starting value for optimization
    # therefore not stable, might have again for other mediators outcome combination.
    # https://stackoverflow.com/questions/28916377/r-error-with-polr-initial-value-in-vmmin-is-not-finite
    formula_m = str_c("mediator", " ~ .") %>% as.formula()
    out.m = MASS::polr(formula_m, data = datt_keep %>% dplyr::select(-gene_set), Hess=TRUE)
  }
  
  
  out<- mediation::mediate(out.m, out.y, treat = "treatment", mediator = "mediator")
  out
}