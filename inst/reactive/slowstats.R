# triggers when the 'go' button is pressed on the PLS-DA tab
observeEvent(input$do_plsda, {
  
  library(e1071)
  library(pls)
  # depending on type, do something else
  # TODO: enable sparse and orthogonal PLS-DA
  switch(input$plsda_type,
         normal={
           require(caret)
           withProgress({
             mSet <<- MetaboAnalystR::PLSR.Anal(mSet) # perform pls regression
             setProgress(0.3)
             mSet <<- MetaboAnalystR::PLSDA.CV(mSet, methodName=if(nrow(mSet$dataSet$norm) < 50) "L" else "T",compNum = 3) # cross validate
             setProgress(0.6)
             mSet <<- MetaboAnalystR::PLSDA.Permut(mSet,num = 300, type = "accu") # permute
           })
         },
         sparse ={
           mSet <<- MetaboAnalystR::SPLSR.Anal(mSet, comp.num = 3)
         })
  # reload pls-da plots
  datamanager$reload <- "plsda"
})

# triggers if 'go' is pressed in the machine learning tab
observeEvent(input$do_ml, {
  shiny::withProgress({
    success=F
    mSet.old <- mSet
    try({
      shiny::setProgress(value = 0)
      
      # get base table to use for process
      curr <- data.table::as.data.table(mSet$dataSet$preproc) # the filtered BUT NOT IMPUTED table, ML should be able to deal w/ missing values
      
      # replace NA's with zero
      curr <- curr[,(1:ncol(curr)) := lapply(.SD,function(x){ifelse(is.na(x),0,x)})]
      
      # conv to data frame
      curr <- as.data.frame(curr)
      rownames(curr) <- rownames(mSet$dataSet$preproc)

      
      # find the qc rows and remove them
      is.qc <- grepl("QC|qc", rownames(curr))
      if(sum(is.qc) > 0){
        curr <- curr[!is.qc,]
      }
      # reorder according to covars table (will be used soon)
      
      order <- match(mSet$dataSet$covars$sample,rownames(curr))
      if("label" %in% colnames(mSet$dataSet$covars)){
        config <- mSet$dataSet$covars[order, -"label"]
      }else{
        config <- mSet$dataSet$covars[order, ]
      }
      
      config <- config[,input$ml_include_covars,with=F]# reorder so both halves match up later
      if(mSet$dataSet$exp.type %in% c("2f", "t1f")){
        # just set to facA for now..
        if(nrow(config)==0){
          config <- data.frame(label=mSet$dataSet$facA[order])
        }else{
          config <- cbind(config, label=mSet$dataSet$facA[order]) # add current experimental condition
        }
      }else{
        if(nrow(config)==0){
          config <- data.frame(label=mSet$dataSet$cls[order])
        }else{
          config <- cbind(config, label=mSet$dataSet$cls[order]) # add current experimental condition
        }
      }
      config <- data.table::as.data.table(config)
      config <- config[,apply(!is.na(config), 2, any), with=FALSE]
      
      predictor = config$label
      predict_idx <- which(colnames(config)== "label")
      exact_matches <- which(unlist(lapply(config, function(col) all(col == predictor))))
      remove = setdiff(exact_matches, predict_idx)
      
      # remove ones w/ every row being different(may be used to identify...)
      #covariates <- lapply(1:ncol(config), function(i) as.factor(config[,..i][[1]]))
      #names(covariates) <- colnames(config)
      
      # # remove ones with na present
      has.na <- apply(config, MARGIN=2, FUN=function(x) any(is.na(x) | tolower(x) == "unknown"))
      has.all.unique <- apply(config, MARGIN=2, FUN=function(x) length(unique(x)) == length(x))
      remove = colnames(config)[which(has.na | has.all.unique)]
      
      #keep_configs <- which(names(config) == "label")
      remove <- unique(c(remove, "sample",  
                         "individual", 
                         colnames(config)[caret::nearZeroVar(config)]))
      
      keep_configs <- which(!(colnames(config) %in% remove))
      
      try({
        shiny::showNotification(paste0("Keeping non-mz variables after NA/unique filtering: ",
                                       paste0(names(config)[keep_configs],collapse = ", ")))
      })
            
      config <- config[,..keep_configs,with=F]
      
      # rename the variable of interest to 0-1-2 etc.
      
      char.lbl <- as.character(config$label)
      uniques <- unique(char.lbl)
      uniques_new_name <- c(1:length(uniques))
      names(uniques_new_name) = uniques
      
      remapped.lbl <- uniques_new_name[char.lbl]
      
      # - - - - - - - - - - - - - - - - - - - - - - -
      
      # join halves together, user variables and metabolite data
      curr <- cbind(config, curr)
      curr <- data.table::as.data.table(curr)
      
      # how many models will be built? user input
      goes = as.numeric(input$ml_attempts)
      
      if(is.null(lcl$vectors$ml_train)){
        lcl$vectors$ml_train <<- c("all", "all")
      }
      if(is.null(lcl$vectors$ml_test)){
        lcl$vectors$ml_test <<- c("all", "all")
      }
      
      if(all(lcl$vectors$ml_test == lcl$vectors$ml_train)){
        if(unique(lcl$vectors$ml_test) == "all"){
          shiny::showNotification("No subset selected... continuing in normal non-subset mode")
        }else{
          MetaboShiny::metshiAlert("Cannot test on the training set!")
          return(NULL)
        }
      }
      
      # identify which columns are metabolites and which are config/covars
      configCols <- which(!(gsub(x = colnames(curr), pattern = "_T\\d", replacement="") %in% colnames(mSet$dataSet$norm)))
      mzCols <- which(gsub(x = colnames(curr), pattern = "_T\\d", replacement="") %in% colnames(mSet$dataSet$norm))
      
      # make the covars factors and the metabolites numeric.
      nums <- which(unlist(lapply(curr, is.numeric))) 
      configCols <- setdiff(configCols, nums)
      
      curr[,(configCols):= lapply(.SD, function(x) as.factor(x)), .SDcols = configCols]
      
      curr[,(mzCols):= lapply(.SD, function(x) as.numeric(x)), .SDcols = mzCols]
      
      # = tuning = 
      require(caret)
      
      # all methods
      caret.mdls <- caret::getModelInfo()
      caret.methods <- names(caret.mdls)
      tune.opts <- lapply(caret.methods, function(mdl) caret.mdls[[mdl]]$parameters)
      names(tune.opts) <- caret.methods
      
      meth.info <- caret.mdls[[input$ml_method]]
      params = meth.info$parameters
      
      #grid.def <- meth.info$grid(training, trainY, len = 1)
      
      tuneGrid = expand.grid(
        {
          lst = lapply(1:nrow(params), function(i){
            info = params[i,]
            inp.val = input[[paste0("ml_", info$parameter)]]
            # - - check for ranges - -
            if(grepl(inp.val, pattern=":")){
              split = strsplit(inp.val,split = ":")[[1]]
              inp.val <- seq(as.numeric(split[1]),
                             as.numeric(split[2]),
                             as.numeric(split[3]))
            }else if(grepl(inp.val, pattern = ",")){
              split = strsplit(inp.val,split = ",")[[1]]
              inp.val <- split
            }
            # - - - - - - - - - - - - -
            switch(as.character(info$class),
                   numeric = as.numeric(inp.val),
                   character = as.character(inp.val))
          })
          names(lst) = params$parameter
          if(any(sapply(lst,function(x)all(is.na(x))))){
            cat("Missing param, auto-tuning...")
            lst <- list()
          }
          #lst <- lst[sapply(lst,function(x)all(!is.na(x)))]
          lst
        })
      
      # ============ DOWNSAMPLE ===========
      if(input$downsample){
        keepers = caret::downSample(1:nrow(curr), curr$label)$x
        curr = curr[keepers,]
      }
      # ============ LOOP HERE ============
      
      print(dim(curr))
      
      # get results for the amount of attempts chosen
      shiny::withProgress(message = "Running...",{
        repeats <- pbapply::pblapply(1:goes,
                                     cl=session_cl,
                                     function(i,
                                              train_vec = train_vec,
                                              test_vec = test_vec,
                                              configCols = configCols,
                                              ml_method = ml_method,
                                              ml_perf_metr = ml_perf_metr,
                                              ml_folds = ml_folds,
                                              ml_preproc = ml_preproc,
                                              tuneGrid = tuneGrid,
                                              ml_train_perc = ml_train_perc){
                                       
                                       # get user training percentage
                                       ml_train_perc <- ml_train_perc/100
                                       
                                       if(unique(train_vec)[1] == "all" & unique(test_vec)[1] == "all"){ # BOTH ARE NOT DEFINED
                                         test_idx = caret::createDataPartition(y = curr$label, p = ml_train_perc, list = FALSE) # partition data in a balanced way (uses labels)
                                         train_idx = setdiff(1:nrow(curr), test_idx) #use the other rows for testing
                                         inTrain = train_idx
                                         inTest = test_idx
                                       }else if(unique(train_vec)[1] != "all"){ #ONLY TRAIN IS DEFINED
                                         train_idx <- which(config[,train_vec[1], with=F][[1]] == train_vec[2])
                                         test_idx = setdiff(1:nrow(curr), train_idx) # use the other rows for testing
                                         reTrain <- caret::createDataPartition(y = config[train_idx, label], p = ml_train_perc) # take a user-defined percentage of the regexed training set
                                         inTrain <- train_idx[reTrain$Resample1]
                                         inTest = test_idx
                                       }else{ # ONLY TEST IS DEFINED
                                         test_idx = which(config[,test_vec[1], with=F][[1]] == test_vec[2])
                                         train_idx = setdiff(1:nrow(curr), test_idx) # use the other rows for testing
                                         reTrain <- caret::createDataPartition(y = config[train_idx, label], p = ml_train_perc) # take a user-defined percentage of the regexed training set
                                         inTrain <- train_idx[reTrain$Resample1]
                                         inTest <- test_idx
                                       }
                                       
                                       # choose predictor "label" (some others are also included but cross validation will be done on this)
                                       predictor = "label"
                                       
                                       # split training and testing data
                                       trainY <- curr[inTrain,
                                                      ..predictor][[1]]
                                       testY <- curr[inTest,
                                                     ..predictor][[1]]
                                       
                                       training <- curr[inTrain,]
                                       testing <- curr[inTest,]
                                       
                                       require(caret)
                                       
                                       if(ml_folds == "LOOCV"){
                                         trainCtrl <- caret::trainControl(verboseIter = T,
                                                                          allowParallel = F,
                                                                          method="LOOCV",
                                                                          trim=TRUE, 
                                                                          returnData = FALSE) # need something here...
                                         
                                       }else{
                                         trainCtrl <- caret::trainControl(verboseIter = T,
                                                                          allowParallel = F,
                                                                          method=as.character(ml_perf_metr),
                                                                          number=as.numeric(ml_folds),
                                                                          repeats=3,
                                                                          trim=TRUE, 
                                                                          returnData = FALSE) # need something here...
                                       }
                                       
                                       fit <- caret::train(
                                         label ~ .,
                                         data = training,
                                         method = ml_method,
                                         ## Center and scale the predictors for the training
                                         ## set and all future samples.
                                         preProc = ml_preproc,
                                         tuneGrid = if(nrow(tuneGrid) > 0) tuneGrid else NULL,
                                         trControl = trainCtrl
                                       )
                                       
                                       result.predicted.prob <- stats::predict(fit, testing, type="prob") # Prediction
                                       
                                       # train and cross validate model
                                       # return list with mode, prediction on test data etc.s
                                       list(type = ml_method,
                                            # model = fit,
                                            importance = caret::varImp(fit)$importance,
                                            prediction = result.predicted.prob[,2],
                                            labels = testing$label)
                                     },
                                     train_vec = lcl$vectors$ml_train,
                                     test_vec = lcl$vectors$ml_test,
                                     configCols = configCols,
                                     ml_method = input$ml_method,
                                     ml_perf_metr = input$ml_perf_metr,
                                     ml_folds = input$ml_folds,
                                     ml_preproc = input$ml_preproc,
                                     tuneGrid = tuneGrid,
                                     ml_train_perc <- input$ml_train_perc
        )
      })
      # check if a storage list for machine learning results already exists
      if(!"ml" %in% names(mSet$analSet)){
        mSet$analSet$ml <<- list() # otherwise make it
      }
      
      mz.imp <- lapply(repeats, function(x) x$importance)
      
      # aucs
      if(length(levels(mSet$dataSet$cls)) > 2){
        perf <- lapply(1:length(repeats), function(i){
          x = repeats[[i]]
          roc = pROC::multiclass.roc(x$labels, x$prediction)
          data.table::rbindlist(lapply(roc$rocs, function(roc.pair){
            data.table(attempt = c(i),
                       FPR = sapply(roc.pair$specificities, function(x) 1-x),
                       TPR = roc.pair$sensitivities,
                       AUC = as.numeric(roc$auc),
                       comparison = paste0(roc.pair$levels,collapse=" vs. "))
          }))
        })
        perf.long <- data.table::rbindlist(perf)
        mean.auc <- mean(perf.long$AUC)
      }else{
        # save the summary of all repeats (will be used in plots) TOO MEMORY HEAVY
        pred <- ROCR::prediction(lapply(repeats, function(x) x$prediction), 
                                 lapply(repeats, function(x) x$labels))
        perf <- ROCR::performance(pred, "tpr", "fpr")
        perf_auc <- ROCR::performance(pred, "auc")
        perf.long <- data.table::rbindlist(lapply(1:length(perf@x.values), function(i){
          xvals <- perf@x.values[[i]]
          yvals <- perf@y.values[[i]]
          aucs <- signif(perf_auc@y.values[[i]][[1]], digits = 2)
          
          res <- data.table::data.table(attempt = c(i),
                                        FPR = xvals,
                                        TPR = yvals,
                                        AUC = aucs)
          res
        }))
        perf.long$comparison <- paste0(levels(mSet$dataSet$cls),collapse=" vs. ")
        mean.auc <- mean(unlist(perf_auc@y.values))
      }
      
      roc_data <- list(m_auc = mean.auc,
                       perf = perf.long,
                       imp = mz.imp)
      
      bar_data <- data.table::rbindlist(lapply(1:length(repeats), function(i){
        x = repeats[[i]]
        tbl = data.table::as.data.table(x$importance, keep.rownames=T)
        tbl$rep = c(i)
        colnames(tbl) = c("mz",
                          "importance",
                          "rep")
        # - - - - - - -
        tbl
      }))
      
      if(input$ml_method == "glmnet"){
        bar_filt = bar_data[importance > 0]
        all_mz <- table(bar_filt$mz)
        tbl = data.table::as.data.table(t(all_mz))[,2:3]
        colnames(tbl) = c("mz", "importance")
        tbl$dummy <- c(NA)
        bar_data <- tbl
      }
      # save results to mset
      mSet$analSet$ml[[input$ml_method]][[input$ml_name]] <- list("roc" = roc_data,
                                                                   "bar" = bar_data)
      mSet$analSet$ml$last <- list(name = input$ml_name,
                                    method = input$ml_method)
      
      success = T
    })
    if(success){
      mSet <<- mSet
      datamanager$reload <- "ml"
    }else{
      MetaboShiny::metshiAlert("Machine learning failed! Is one of your groups too small? Please retry with other settings.")
      NULL
    }
  })
})

# mummichog 
#TODO: re-enable, currently ouchy broken...
observeEvent(input$do_mummi, {
  
  peak_tbl <- if(mSet$dataSet$cls.num == 2){
    if("tt" %in% names(mSet$analSet)){
      continue = T
      data.table::data.table(
        `p.value` = mSet$analSet$tt$sig.mat[,"p.value"],
        `m.z` = rownames(mSet$analSet$tt$sig.mat),
        `t.score` = mSet$analSet$tt$sig.mat[,if("V" %in% colnames(mSet$analSet$tt$sig.mat)) "V" else "t.stat"]
      )
    }else{continue=F;
    NULL}
  }else{
    if("aov" %in% names(mSet$analSet)){
      continue = T
      data.table::data.table(
        `p.value` = mSet$analSet$aov$sig.mat[,"p.value"],
        `m.z` = rownames(mSet$analSet$aov$sig.mat),
        `t.score` = mSet$analSet$aov$sig.mat[,"F.stat"]
      )
    }else{continue=F;
    NULL}
  }
  
  if(!continue) NULL
  
  # seperate in pos and neg peaks..
  conn <- RSQLite::dbConnect(RSQLite::SQLite(), lcl$paths$patdb)
  pospeaks <- DBI::dbGetQuery(conn, "SELECT DISTINCT mzmed FROM mzvals WHERE foundinmode = 'positive'")
  negpeaks <- DBI::dbGetQuery(conn, "SELECT DISTINCT mzmed FROM mzvals WHERE foundinmode = 'negative'")
  peak_tbl_pos <- peak_tbl[`m.z` %in% unlist(pospeaks)]
  peak_tbl_neg <- peak_tbl[`m.z` %in% unlist(negpeaks)]
  DBI::dbDisconnect(conn)
  
  for(mode in c("positive", "negative")){
    
    path <- tempfile()
    fwrite(x = peak_tbl, file = path, sep = "\t")
    mummi <- MetaboAnalystR::InitDataObjects("mass_all", "mummichog", FALSE)
    mummi <- MetaboAnalystR::Read.PeakListData(mSetObj = mummi, filename = path);
    mummi <- MetaboAnalystR::UpdateMummichogParameters(mummi, as.character(input$mummi_ppm), mode, input$mummi_sigmin);
    mummi <- MetaboAnalystR::SanityCheckMummichogData(mummi)
    mummi <- MetaboAnalystR::PerformMummichog(mummi, input$mummi_org, "fisher", "gamma")
    
    lcl$vectors[[paste0("mummi_", substr(mode, 1, 3))]] <<- list(sig = mummi$mummi.resmat,
                                                                 pw2cpd = {
                                                                   lst = mummi$pathways$cpds
                                                                   names(lst) <- mummi$pathways$name
                                                                   # - - -
                                                                   lst
                                                                 },
                                                                 cpd2mz = mummi$cpd2mz_dict)
    lcl$tables$mummichog <<- mummi$mummi.resmat
    output[[paste0("mummi_", substr(mode, 1, 3), "_tab")]] <- DT::renderDataTable({
      DT::datatable(mummi$mummi.resmat,selection = "single")
    })
  }
  output[[paste0("mummi_detail_tab")]] <- DT::renderDataTable({
    DT::datatable(data.table("no pathway selected"="Please select a pathway!"))
  })
})
