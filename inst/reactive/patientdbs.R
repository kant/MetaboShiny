# create checkcmarks if database is present
lapply(c("merge", "csv"), FUN=function(col){
  # creates listener for if the 'check db' button is pressed
  shiny::observe({
    # see which db files are present in folder
    folder_files <- list.files(lcl$paths$work_dir)
    is.present <- switch(col,
                         merge = is.list(input$metadata) & is.list(input$outlist_pos) & is.list(input$outlist_neg),
                         csv = paste0(input$proj_name_new, ".csv") %in% folder_files)
    check_pic <- if(is.present) "yes.png" else "no.png"
    # generate checkmark image objects
    output[[paste0("proj_", col, "_check")]] <- shiny::renderImage({
      filename <- normalizePath(file.path('www', check_pic))
      list(src = filename, width = 70,
           height = 70)
    }, deleteFile = FALSE)# <- this is important or the checkmark file is deleted, haha
  })
})

# triggers when user wants to create database from .db and excel or 2 csv files and excel
shiny::observeEvent(input$create_db,{

  files.present = is.list(input$metadata) & is.list(input$outlist_pos) & is.list(input$outlist_neg)

  if(!files.present) return(NULL)
  
  # update the path to patient db
  lcl$paths$patdb <<- file.path(lcl$paths$work_dir, paste0(lcl$proj_name, ".db"))

  shiny::withProgress({

    shiny::setProgress(session=session, value= .1)

    proj_name = input$proj_name_new

    shiny::updateSelectizeInput(session = session,
                         inputId = "proj_name",
                         choices = c(lcl$vectors$project_names, proj_name))

    shiny::updateSelectizeInput(session = session,
                         inputId = "proj_name",
                         selected = proj_name)

    lcl$proj_name <<- proj_name
    lcl$paths$patdb <<- file.path(lcl$paths$work_dir, paste0(lcl$proj_name, ".db"))
    # change project name in user options file
    MetaboShiny::setOption(lcl$paths$opt.loc, key="proj_name", value=lcl$proj_name)
    # print the changed name in the UI
    output$proj_name <<- shiny::renderText(proj_name)
    # change path CSV should be / is saved to in session
    #lcl$paths$csv_loc <<- file.path(lcl$paths$work_dir, paste0(lcl$proj_name,".csv"))
    # if loading in .csv files...
    MetaboShiny::build.pat.db(db.name = lcl$paths$patdb,
                              ppm = input$ppm,
                              pospath = shinyFiles::parseFilePaths(gbl$paths$volumes, input$outlist_pos)$datapath,
                              negpath = shinyFiles::parseFilePaths(gbl$paths$volumes, input$outlist_neg)$datapath,
                              metapath = shinyFiles::parseFilePaths(gbl$paths$volumes, input$metadata)$datapath,
                              wipe.regex = input$wipe_regex,
                              overwrite = T)
    
    output$proj_db_check <- shiny::renderImage({
      filename <- normalizePath(file.path('www', "yes.png"))
      list(src = filename, width = 70,
           height = 70)
      },deleteFile = FALSE)
    })
})

# imports existing db file
# TODO: is deprecated, fix!!
shiny::observeEvent(input$import_db, {
  lcl$paths$patdb <<- input$pat_db$datapath
  output$db_upload_check <- shiny::renderImage({
    # When input$n is 3, filename is ./images/image3.jpeg
    filename <- normalizePath('www/yes.png')
    # Return a list containing the filename and alt text
    list(src = filename, width = 20,
         height = 20)
  }, deleteFile = FALSE)
})

# imports existing csv file
shiny::observeEvent(input$import_csv, {
  # change path to current csv file to user given path
  lcl$paths$csv_loc <<- input$pat_csv$datapath

  # show checkmark underneath select csv button
  output$csv_upload_check <- shiny::renderImage({
    # When input$n is 3, filename is ./images/image3.jpeg
    filename <- normalizePath('www/yes.png')
    # Return a list containing the filename and alt text
    list(src = filename, width = 20,
         height = 20)
  }, deleteFile = FALSE)
})


# is triggered when the create csv button is clicked
shiny::observeEvent(input$create_csv, {

    conn <- RSQLite::dbConnect(RSQLite::SQLite(), normalizePath(lcl$paths$patdb))
    
    cat("Checking for mismatches between peak tables and metadata... \n")
    
    fn_meta <- RSQLite::dbGetQuery(conn, "SELECT DISTINCT sample FROM individual_data")[,1]
    fn_int <- RSQLite::dbGetQuery(conn, "SELECT DISTINCT filename FROM mzintensities")[,1]
    
    cat(paste0("-- in peaklist, not in metadata: --- \n", 
               paste0(setdiff(fn_int,
                              fn_meta), 
                      collapse=", "), 
               "\n"))
    cat(paste0("-- in metadata, not in peaklist: --- \n", 
               paste0(setdiff(fn_meta,
                              fn_int), 
                      collapse=", "), 
               "\n\n"))
    
    if(DBI::dbExistsTable(conn, "setup")){
      query <- strwrap(gsubfn::fn$paste("select distinct d.sample as sample, d.*, s.*
                                        from mzintensities i
                                        join individual_data d
                                        on i.filename = d.sample
                                        join setup s on d.[Group] = s.[Group]"),
                       width=10000,
                       simplify=TRUE)   
    }else{
      query <- strwrap(gsubfn::fn$paste("select distinct d.sample as sample, d.*
                                        from mzintensities i
                                        join individual_data d
                                        on i.filename = d.sample"),
                       width=10000,
                       simplify=TRUE)
    }
   
    RSQLite::dbExecute(conn, "PRAGMA journal_mode=WAL;")
    RSQLite::dbExecute(conn, "CREATE INDEX IF NOT EXISTS filenames ON mzintensities(filename)")
    
    all_mz = RSQLite::dbGetQuery(conn, "select distinct i.mzmed
                                        from mzintensities i
                                        join individual_data d
                                        on i.filename = d.sample")[,1]
    
    RSQLite::dbDisconnect(conn)
    
    lcl$paths$csv_loc <<- gsub(lcl$paths$patdb, 
                          pattern = "\\.db", 
                          replacement = ".csv")
    if(file.exists(lcl$paths$csv_loc)) file.remove(lcl$paths$csv_loc)
    
    shiny::withProgress(min = 0, max = 1, {
      # write rows to csv
      lapply(fn_meta, 
             #cl = session_cl, 
             function(filename){
               
                # connect
               conn <- RSQLite::dbConnect(RSQLite::SQLite(), normalizePath(lcl$paths$patdb))
               
               # adjust query
               query_add = gsubfn::fn$paste(" WHERE i.filename = '$filename'")
               
               # get results for sample
               z.meta = data.table::as.data.table(RSQLite::dbGetQuery(conn, paste0(query, query_add)))
               
               if(nrow(z.meta)==0) return(NA)
               
               #z.meta = z.meta[,-c("sample", "sampling_date")]
               
               colnames(z.meta) <- tolower(colnames(z.meta))
               z.int = data.table::as.data.table(RSQLite::dbGetQuery(conn, 
                                        paste0("SELECT DISTINCT
                                                i.mzmed as identifier,
                                                i.intensity
                                                FROM mzintensities i", query_add)))
               
               if(nrow(z.int)==0) return(NA)
               
               missing_mz <- setdiff(all_mz, z.int$identifier)
               
               # cast to wide
               cast.dt <- data.table::dcast.data.table(z.int,
                                           formula = ... ~ identifier,
                                           fun.aggregate = sum,
                                           value.var = "intensity")
               
               complete = as.numeric(cast.dt[1,-1])
               names(complete) = colnames(cast.dt)[-1]
               
               missing = rep(NA, length(missing_mz))
               names(missing) <- missing_mz
               
               complete.row = c(complete[-1], missing)
               reordered <- order(as.numeric(names(complete.row)))
               complete.row <- complete.row[reordered]
               complete.row.dt <- data.table::as.data.table(t(data.table::as.data.table(complete.row)))
               colnames(complete.row.dt) <- names(complete.row)
               
               RSQLite::dbDisconnect(conn)
               
               z.meta$sample <- gsub(z.meta$sample, pattern=" |\\(|\\)|\\+", replacement="")
               
               # write
               data.table::fwrite(c(z.meta, complete.row), 
                      file = lcl$paths$csv_loc,
                      append = T)
               
               shiny::incProgress(amount = 1/length(fn_meta))
             })      
    })
    
    # - - measure file size - -
    
    disk_size = file.info(lcl$paths$csv_loc)$size
    size <- utils:::format.object_size(disk_size, "Mb")
    cat(paste("... Resulting file is approximately"),size,"...")

    # render overview table
    output$csv_tab <-DT::renderDataTable({
      overview_tab <- t(data.table::data.table(keep.rownames = F,
                                   Identifiers = length(all_mz),
                                   Samples = length(fn_meta)))
      colnames(overview_tab) <- "#"
      DT::datatable(overview_tab,
                    selection = 'single',
                    autoHideNavigation = T,
                    options = list(lengthMenu = c(10, 30, 50), pageLength = 30,scrollX=TRUE, scrollY=TRUE))
    })
    output$proj_csv_check <- shiny::renderImage({
      filename <- normalizePath(file.path('www', "yes.png"))
      list(src = filename, width = 70,
           height = 70)
    },deleteFile = FALSE)
})


shiny::observeEvent(input$metadata_new_add, {
  
  meta_path <- shinyFiles::parseFilePaths(gbl$paths$volumes, input$metadata_new)$datapath
  
  try({
    new_meta <- data.table::fread(meta_path)
    new_meta <- MetaboShiny::reformat.metadata(new_meta)
    colnames(new_meta) <- tolower(colnames(new_meta))
    
    missing <- which(!(new_meta$sample %in% mSet$storage$orig$data$covars$sample))
    
    if(length(missing) == nrow(new_meta)){
      MetaboShiny::metshiAlert("Sample name mismatch! Please check your new metadata...")
    }else{
      
      new_meta <- new_meta[-missing,]
      
      # removed_variables?
      missing_variables <- setdiff(colnames(mSet$storage$orig$data$covars), colnames(new_meta))
      if(length(missing_variables)>1){
        # save these to add later
        meta_base <- mSet$storage$orig$data$covars[, ..missing_variables]
      }else{
        meta_base <- data.table::data.table()
      }
      
      # reorder to match old order
      reordered_new_meta <- new_meta[match(new_meta$sample, mSet$storage$orig$data$covars$sample),]
      merged_new_meta <- cbind(reordered_new_meta, meta_base)
      
      mSet <- MetaboShiny::store.mSet(mSet)
      mSet$storage$orig$data$covars <- merged_new_meta
      mSet <- MetaboShiny::reset.mSet(mSet)
      mSet <<- mSet
      
      shiny::showNotification("Updated metadata! Your experiment was saved but your current variable reset.")
      
      datamanager$reload <- "general"  
    }
  })
  
})

# triggers when 'get options' is clicked in the normalization pane
shiny::observeEvent(input$check_csv, {
  # ----------------------

  conn <- RSQLite::dbConnect(RSQLite::SQLite(), normalizePath(lcl$paths$patdb))
  
  metadata <- data.table::as.data.table(RSQLite::dbGetQuery(conn, "SELECT * FROM individual_data"))
  
  exp.vars = colnames(metadata)
  
  # get the names of those experimental variables
  opts <<- colnames(metadata)

  bvars <- if(RSQLite::dbExistsTable(conn, "batchinfo")){
    c("batch", "injection")
  }else{
    c()
  }
  
  # get columns that can be used for batch correction (need to be non-unique)
  batch <<- which(sapply(exp.vars, function(x) length(unique(metadata[,..x][[1]])) < nrow(metadata)))

  # update the possible options in the UI
  shiny::updateSelectInput(session, "samp_var",
                    choices = opts)
  shiny::updateSelectizeInput(session, "batch_var",
                       choices = c(bvars, opts[batch]),
                       options = list(maxItems = 3L - (length(input$batch_var)))
  )
})
