#' Restructure Old \code{brmsfit} Objects
#'
#' Restructure old \code{brmsfit} objects to work with 
#' the latest \pkg{brms} version. This function is called
#' internally when applying post-processing methods.
#' However, in order to avoid unnecessary run time caused
#' by the restructuring, I recommend explicitly calling
#' \code{restructure} once per model after updating \pkg{brms}.
#' 
#' @param x An object of class \code{brmsfit}.
#' @param rstr_summary Logical; If \code{TRUE}, the cached summary
#'   stored by \pkg{rstan} is restructured as well.
#'   
#' @return A \code{brmsfit} object compatible with the latest version
#'   of \pkg{brms}.
#'   
#' @export
restructure <- function(x, rstr_summary = FALSE) {
  stopifnot(is.brmsfit(x))
  if (is.null(x$version)) {
    # this is the latest version without saving the version number
    x$version <- list(brms = package_version("0.9.1"))
  } else if (is.package_version(x$version)) {
    # also added the rstan version in brms 1.5.0
    x$version <- list(brms = x$version)
  }
  if (!isTRUE(attr(x, "restructured"))) {
    if (x$version$brms < "2.0.0") {
      x <- restructure_v1(x)
    }
    x <- restructure_v2(x)
  }
  stan_env <- attributes(x$fit)$.MISC
  if (rstr_summary && exists("summary", stan_env)) {
    stan_summary <- get("summary", stan_env)
    old_parnames <- rownames(stan_summary$msd)
    if (!identical(old_parnames, parnames(x))) {
      # do not rename parameters in the cached summary
      # just let rstan compute the summary again
      remove("summary", pos = stan_env)
    }
  }
  structure(x, restructured = TRUE)
}

restructure_v2 <- function(x) {
  # restructure models fitted with brms 2.x
  version <- x$version$brms
  pars <- parnames(x)
  bterms <- parse_bf(formula(x))
  if (version <= "2.1.1") {
    x <- do_renaming(x, change_old_bsp(pars))
  }
  if (version <= "2.1.2") {
    if ("weibull" %in% family_names(x)) {
      stop_parameterization_changed("weibull", "2.1.3")
    }
  }
  if (version <= "2.1.7") {
    if ("exgaussian" %in% family_names(x)) {
      stop_parameterization_changed("exgaussian", "2.1.8")
    }
  }
  if (version <= "2.1.8") {
    # reworked 'me' terms (#372)
    meef <- tidy_meef(bterms, model.frame(x))
    if (isTRUE(nrow(meef) > 0)) {
      warning2(
        "Measurement error ('me') terms have been reworked ",
        "in version 2.1.9. I strongly recommend refitting your ",
        "model with the latest version of brms."
      )
    }
  }
  if (version <= "2.2.3") {
    # added 'dist' argument to grouping terms
    x$ranef <- tidy_ranef(bterms, model.frame(x))
  }
  if (version <= "2.3.6") {
    check_old_nl_dpars(bterms)
  }
  x
}

restructure_v1 <- function(x) {
  # restructure models fitted with brms 1.x
  version <- x$version$brms
  if (version < "1.0.0") {
    warning2(
      "Models fitted with brms < 1.0 are no longer offically ",
      "supported and post-processing them may fail. I recommend ", 
      "refitting the model with the latest version of brms."
    )
  }
  x$formula <- restructure_formula(formula(x), x$nonlinear)
  x$formula <- SW(validate_formula(
    formula(x), data = model.frame(x), family = family(x),
    autocor = x$autocor, threshold = x$threshold
  ))
  x$nonlinear <- x$partial <- x$threshold <- NULL
  bterms <- parse_bf(formula(x))
  x$data <- rm_attr(x$data, "brmsframe")
  x$data <- update_data(x$data, bterms) 
  x$ranef <- tidy_ranef(bterms, model.frame(x))
  if ("prior_frame" %in% class(x$prior)) {
    class(x$prior) <- c("brmsprior", "data.frame") 
  }
  if (is(x$autocor, "cov_fixed")) {
    # deprecated as of brms 1.4.0
    class(x$autocor) <- "cor_fixed"
  }
  if (version <= "0.10.0.9000") {
    if (length(bterms$dpars$mu$nlpars)) {
      # nlpar and group have changed positions
      change <- change_old_re(x$ranef, parnames(x), x$fit@sim$dims_oi)
      x <- do_renaming(x, change)
    }
  }
  if (version < "1.0.0") {
    # double underscores were added to group-level parameters
    change <- change_old_re2(x$ranef, parnames(x), x$fit@sim$dims_oi)
    x <- do_renaming(x, change)
  }
  if (version <= "1.0.1") {
    # names of spline parameters had to be changed after
    # allowing for multiple covariates in one spline term
    change <- change_old_sm(
      bterms, model.frame(x), parnames(x), x$fit@sim$dims_oi
    )
    x <- do_renaming(x, change)
  }
  if (version <= "1.8.0") {
    att <- attributes(x$exclude)
    if (is.null(att$save_ranef)) {
      attr(x$exclude, "save_ranef") <- 
        any(grepl("^r_", parnames(x))) || !nrow(x$ranef)
    }
    if (is.null(att$save_mevars)) {
      attr(x$exclude, "save_mevars") <- 
        any(grepl("^Xme_", parnames(x)))
    }
  }
  if (version <= "1.8.0.1") {
    x$prior[, c("resp", "dpar")] <- ""
  }
  if (version <= "1.9.0.3") {
    # names of monotonic parameters had to be changed after
    # allowing for interactions in monotonic terms
    change <- change_old_mo(bterms, x$data, pars = parnames(x))
    x <- do_renaming(x, change)
  }
  if (version >= "1.0.0" && version < "2.0.0") {
    change <- change_old_categorical(bterms, x$data, pars = parnames(x))
    x <- do_renaming(x, change)
  }
  x
}

restructure_formula <- function(formula, nonlinear = NULL) {
  # convert old model formulas to brmsformula objects
  if (is.brmsformula(formula) && is.formula(formula)) {
    # convert deprecated brmsformula objects back to formula
    class(formula) <- "formula"
  }
  if (is.brmsformula(formula)) {
    # already up to date
    return(formula)
  }
  old_nonlinear <- attr(formula, "nonlinear")
  nl <- length(nonlinear) > 0
  if (is.logical(old_nonlinear)) {
    nl <- nl || old_nonlinear
  } else if (length(old_nonlinear)) {
    nonlinear <- c(nonlinear, old_nonlinear)
    nl <- TRUE
  }
  out <- structure(nlist(formula), class = "brmsformula")
  old_forms <- rmNULL(attributes(formula)[dpars()])
  old_forms <- c(old_forms, nonlinear)
  out$pforms[names(old_forms)] <- old_forms
  bf(out, nl = nl)
}

change_old_re <- function(ranef, pars, dims) {
  # interchanges group and nlpar in names of group-level parameters
  # for brms <= 0.10.0.9000 only
  # Args:
  #   ranef: output of tidy_ranef
  #   pars: names of all parameters in the model
  #   dims: dimension of parameters
  # Returns:
  #   a list whose elements can be interpreted by do_renaming
  out <- list()
  for (id in unique(ranef$id)) {
    r <- subset2(ranef, id = id)
    g <- r$group[1]
    nlpar <- r$nlpar[1]
    stopifnot(nzchar(nlpar))
    # rename sd-parameters
    old_sd_names <- paste0("sd_", nlpar, "_", g, "_", r$coef)
    new_sd_names <- paste0("sd_", g, "_", nlpar, "_", r$coef)
    for (i in seq_along(old_sd_names)) {
      lc(out) <- change_simple(
        old_sd_names[i], new_sd_names[i], pars, dims
      )
    }
    # rename cor-parameters
    new_cor_names <- get_cornames(
      paste0(nlpar, "_", r$coef), type = paste0("cor_", g),
      brackets = FALSE, sep = "_"
    )
    old_cor_names <- get_cornames(
      r$coef, brackets = FALSE, sep = "_",
      type = paste0("cor_", nlpar, "_", g)
    )
    for (i in seq_along(old_cor_names)) {
      lc(out) <- change_simple(
        old_cor_names[i], new_cor_names[i], pars, dims
      )
    } 
    # rename r-parameters
    old_r_name <- paste0("r_", nlpar, "_", g)
    new_r_name <- paste0("r_", g, "_", nlpar)
    levels <- gsub("[ \t\r\n]", ".", attr(ranef, "levels")[[g]])
    index_names <- make_index_names(levels, r$coef, dim = 2)
    new_r_names <- paste0(new_r_name, index_names)
    lc(out) <- change_simple(
      old_r_name, new_r_names, pars, dims, 
      pnames = new_r_name
    )
  }
  out
}

change_old_re2 <- function(ranef, pars, dims) {
  # add double underscore in group-level parameters
  # for brms < 1.0.0 only
  # assumes that group and nlpar are correctly ordered already
  # Args:
  #   ranef: output of tidy_ranef
  #   pars: names of all parameters in the model
  #   dims: dimension of parameters
  # Returns:
  #   a list whose elements can be interpreted by do_renaming
  out <- list()
  for (id in unique(ranef$id)) {
    r <- subset2(ranef, id = id)
    g <- r$group[1]
    nlpars_usc <- usc(r$nlpar, "suffix")
    # rename sd-parameters
    old_sd_names <- paste0("sd_", g, "_", nlpars_usc, r$coef)
    new_sd_names <- paste0("sd_", g, "__", nlpars_usc, r$coef)
    for (i in seq_along(old_sd_names)) {
      lc(out) <- change_simple(old_sd_names[i], new_sd_names[i], pars, dims)
    }
    # rename cor-parameters
    new_cor_names <- get_cornames(
      paste0(nlpars_usc, r$coef), type = paste0("cor_", g),
      brackets = FALSE
    )
    old_cor_names <- get_cornames(
      paste0(nlpars_usc, r$coef), type = paste0("cor_", g),
      brackets = FALSE, sep = "_"
    )
    for (i in seq_along(old_cor_names)) {
      lc(out) <- change_simple(old_cor_names[i], new_cor_names[i], pars, dims)
    } 
    # rename r-parameters
    for (nlpar in unique(r$nlpar)) {
      sub_r <- r[r$nlpar == nlpar, ]
      old_r_name <- paste0("r_", g, usc(nlpar))
      new_r_name <- paste0("r_", g, usc(usc(nlpar)))
      levels <- gsub("[ \t\r\n]", ".", attr(ranef, "levels")[[g]])
      index_names <- make_index_names(levels, sub_r$coef, dim = 2)
      new_r_names <- paste0(new_r_name, index_names)
      lc(out) <- change_simple(
        old_r_name, new_r_names, pars, dims, 
        pnames = new_r_name
      )
    }
  }
  out
}

change_old_sm <- function(bterms, data, pars, dims) {
  # change names of spline parameters fitted with brms <= 1.0.1
  # this became necessary after allowing smooths with multiple covariates
  .change_old_sm <- function(bt) {
    out <- list()
    smef <- tidy_smef(bt, data)
    if (nrow(smef)) {
      p <- usc(combine_prefix(bt), "suffix")
      old_smooths <- rename(paste0(p, smef$term))
      new_smooths <- rename(paste0(p, smef$label))
      old_sds_pars <- paste0("sds_", old_smooths)
      new_sds_pars <- paste0("sds_", new_smooths, "_1")
      old_s_pars <- paste0("s_", old_smooths)
      new_s_pars <- paste0("s_", new_smooths, "_1")
      for (i in seq_along(old_smooths)) {
        lc(out) <- change_simple(old_sds_pars[i], new_sds_pars[i], pars, dims)
        dim_s <- dims[[old_s_pars[i]]]
        if (!is.null(dim_s)) {
          new_s_par_indices <- paste0(new_s_pars[i], "[", seq_len(dim_s), "]")
          lc(out) <- change_simple(
            old_s_pars[i], new_s_par_indices, pars, dims,
            pnames = new_s_pars[i]
          )
        }
      }
    }
    return(out)
  }
  
  out <- list()
  if (is.mvbrmsterms(bterms)) {
    for (r in bterms$responses) {
      c(out) <- .change_old_sm(bterms$terms[[r]]$dpars$mu)
    }
  } else if (is.brmsterms(bterms)) {
    for (dp in names(bterms$dpars)) {
      bt <- bterms$dpars[[dp]]
      if (length(bt$nlpars)) {
        for (nlp in names(bt$nlpars)) {
          c(out) <- .change_old_sm(bt$nlpars[[nlp]])
        }
      } else {
        c(out) <- .change_old_sm(bt)
      }
    }
  }
  out
}

change_old_mo <- function(bterms, data, pars) {
  # change names of monotonic effects fitted with brms <= 1.9.0
  # this became necessary after implementing monotonic interactions
  .change_old_mo <- function(bt) {
    out <- list()
    spef <- tidy_spef(bt, data)
    has_mo <- lengths(spef$call_mo) > 0
    if (!any(has_mo)) {
      return(out)
    }
    spef <- spef[has_mo, ]
    p <- usc(combine_prefix(bt))
    bmo_prefix <- paste0("bmo", p, "_")
    bmo_regex <- paste0("^", bmo_prefix, "[^_]+$")
    bmo_old <- pars[grepl(bmo_regex, pars)]
    bmo_new <- paste0(bmo_prefix, spef$coef)
    if (length(bmo_old) != length(bmo_new)) {
      stop2("Restructuring failed. Please refit your ", 
            "model with the latest version of brms.")
    }
    for (i in seq_along(bmo_old)) {
      pos <- grepl(paste0("^", bmo_old[i]), pars)
      lc(out) <- clist(pos, fnames = bmo_new[i])
    }
    simo_regex <- paste0("^simplex", p, "_[^_]+$")
    simo_old_all <- pars[grepl(simo_regex, pars)]
    simo_index <- get_matches("\\[[[:digit:]]+\\]$", simo_old_all)
    simo_old <- unique(sub("\\[[[:digit:]]+\\]$", "", simo_old_all))
    simo_coef <- get_simo_labels(spef)
    for (i in seq_along(simo_old)) {
      regex_pos <- paste0("^", simo_old[i])
      pos <- grepl(regex_pos, pars)
      simo_new <- paste0("simo", p, "_", simo_coef[i])
      simo_index_part <- simo_index[grepl(regex_pos, simo_old_all)]
      simo_new <- paste0(simo_new, simo_index_part)
      lc(out) <- clist(pos, fnames = simo_new)
    }
    return(out)
  }
  
  out <- list()
  if (is.mvbrmsterms(bterms)) {
    for (r in bterms$responses) {
      c(out) <- .change_old_mo(bterms$terms[[r]]$dpars$mu)
    }
  } else if (is.brmsterms(bterms)) {
    for (dp in names(bterms$dpars)) {
      bt <- bterms$dpars[[dp]]
      if (length(bt$nlpars)) {
        for (nlp in names(bt$nlpars)) {
          c(out) <- .change_old_mo(bt$nlpars[[nlp]])
        }
      } else {
        c(out) <- .change_old_mo(bt)
      }
    }
  }
  out
}

change_old_categorical <- function(bterms, data, pars) {
  # between version 1.0 and 2.0 categorical models used
  # the internal multivariate interface
  stopifnot(is.brmsterms(bterms))
  if (!is_categorical(bterms$family)) {
    return(list())
  }
  # compute the old category names
  respform <- bterms$respform
  old_dpars <- model.response(model.frame(respform, data = data))
  old_dpars <- levels(factor(old_dpars))
  old_dpars <- make.names(old_dpars[-1], unique = TRUE)
  old_dpars <- rename(old_dpars, ".", "x")
  new_dpars <- bterms$family$dpars
  stopifnot(length(old_dpars) == length(new_dpars))
  pos <- rep(FALSE, length(pars))
  new_pars <- pars
  for (i in seq_along(old_dpars)) {
    # not perfectly save but hopefully mostly correct
    regex <- paste0("(?<=_)", old_dpars[i], "(?=_|\\[)")
    pos <- pos | grepl(regex, pars, perl = TRUE)
    new_pars <- gsub(regex, new_dpars[i], new_pars, perl = TRUE)
  }
  list(nlist(pos, fnames = new_pars[pos]))
}

change_old_bsp <- function(pars) {
  # as of brms 2.2 'mo' and 'me' terms are handled together
  pos <- grepl("^(bmo|bme)_", pars)
  if (!any(pos)) return(list()) 
  fnames <- gsub("^(bmo|bme)_", "bsp_", pars[pos])
  list(nlist(pos, fnames))
}

change_simple <- function(oldname, fnames, pars, dims, pnames = fnames) {
  # helper function for very simple renaming
  # only used in renaming of old models
  pos <- grepl(paste0("^", oldname), pars)
  if (any(pos)) {
    out <- nlist(pos, oldname, pnames, fnames, dims = dims[[oldname]])
    class(out) <- c("clist", "list")
  } else {
    out <- NULL
  }
  out
}

stop_parameterization_changed <- function(family, version) {
  stop2(
    "The parameterization of '", family, "' models has changed in brms ",
    version, " to be consistent with other model classes. ", 
    "Please refit your model with the current version of brms."
  )
}

check_old_nl_dpars <- function(bterms) {
  .check_nl_dpars <- function(x) {
    stopifnot(is.brmsterms(x))
    non_mu_dpars <- x$dpars[names(x$dpars) != "mu"]
    if (any(ulapply(non_mu_dpars, is.btnl))) {
      stop2(
        "Non-linear parameters are global within univariate models ",
        "as of version 2.3.7. Please refit your model with the ",
        "latest version of brms."
      )
    }
    return(TRUE)
  }
  if (is.mvbrmsterms(bterms)) {
    lapply(bterms$terms, .check_nl_dpars)
  } else {
    .check_nl_dpars(bterms)
  }
  TRUE
}
