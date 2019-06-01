library(meetupr)

#internals.R from rladies/meetupr package
# This helper function makes a single call, given the full API endpoint URL
# Used as the workhorse function inside .fetch_results() below
.quick_fetch <- function(api_url,
                         api_key = NULL,
                         event_status = NULL,
                         ...) {
  
  # list of parameters
  parameters <- list(key = api_key,         # your api_key
                     status = event_status, # you need to add the status
                     # otherwise it will get only the upcoming event
                     ...                    # other parameters
  )
  
  req <- httr::GET(url = api_url,          # the endpoint
                   query = parameters)
  
  httr::stop_for_status(req)
  reslist <- httr::content(req, "parsed")
  
  if (length(reslist) == 0) {
    stop("Zero records match your filter. Nothing to return.\n",
         call. = FALSE)
  }
  
  return(list(result = reslist, headers = req$headers))
}


# Fetch all the results of a query given an API Method
# Will make multiple calls to the API if needed
# API Methods listed here: https://www.meetup.com/meetup_api/docs/
.fetch_results <- function(api_method, api_key = NULL, event_status = NULL, ...) {
  
  # Build the API endpoint URL
  meetup_api_prefix <- "https://api.meetup.com/"
  api_url <- paste0(meetup_api_prefix, api_method)
  
  # Get the API key from MEETUP_KEY environment variable if NULL
  if (is.null(api_key)) api_key <- .get_api_key()
  if (!is.character(api_key)) stop("api_key must be a character string")
  
  # Fetch first set of results (limited to 200 records each call)
  res <- .quick_fetch(api_url = api_url,
                      api_key = api_key,
                      event_status = event_status,
                      ...)
  
  # Total number of records matching the query
  total_records <- as.integer(res$headers$`x-total-count`)
  if (length(total_records) == 0) total_records <- 1L
  records <- res$result
  cat(paste("Downloading", total_records, "record(s)..."))
  
  # If you have not yet retrieved all records, calculate the # of remaining calls required
  extra_calls <- ifelse(
    (length(records) < total_records) & !is.null(res$headers$link),
    floor(total_records/length(records)),
    0)
  if (extra_calls > 0) {
    all_records <- list(records)
    for (i in seq(extra_calls)) {
      # Keep making API requests with an increasing offset value until you get all the records
      # TO DO: clean this strsplit up or replace with regex
      
      next_url <- strsplit(strsplit(res$headers$link, split = "<")[[1]][2], split = ">")[[1]][1]
      res <- .quick_fetch(next_url, api_key, event_status)
      all_records[[i + 1]] <- res$result
    }
    records <- unlist(all_records, recursive = FALSE)
  }
  
  return(records)
}


# helper function to convert a vector of milliseconds since epoch into POSIXct
.date_helper <- function(time) {
  if (is.character(time)) {
    # if date is character string, try to convert to numeric
    time <- tryCatch(expr = as.numeric(time),
                     error = warning("One or more dates could not be converted properly"))
  }
  if (is.numeric(time)) {
    # divide milliseconds by 1000 to get seconds; convert to POSIXct
    seconds <- time / 1000
    out <- as.POSIXct(seconds, origin = "1970-01-01")
  } else {
    # if no conversion can be done, then return NA
    warning("One or more dates could not be converted properly")
    out <- rep(NA, length(time))
  }
  return(out)
}

# function to return meetup.com API key stored in the MEETUP_KEY environment variable
.get_api_key <- function() {
  api_key <- Sys.getenv("MEETUP_KEY")
  if (api_key == "") {
    stop("You have not set a MEETUP_KEY environment variable.\nIf you do not yet have a meetup.com API key, you can retrieve one here:\n  * https://secure.meetup.com/meetup_api/key/",
         call. = FALSE)
  }
  return(api_key)
}


##---------------------------------------
# updated get_events() function to retrieve the optional field `event_hosts`

get_events <- function(urlname, event_status = "upcoming", fields = NULL, api_key = NULL) {
  if (!is.null(event_status) &&
      !event_status %in% c("cancelled", "draft", "past", "proposed", "suggested", "upcoming")) {
    stop(sprintf("Event status %s not allowed", event_status))
  }
  # If event_status contains multiple statuses, we can pass along a comma sep list
  if (length(event_status) > 1) {
    event_status <- paste(event_status, collapse = ",")
  }
  api_method <- paste0(urlname, "/events")
  res <- .fetch_results(api_method, api_key, event_status, fields = fields)
  tibble::tibble(
    id = purrr::map_chr(res, "id"),  #this is returned as chr (not int)
    name = purrr::map_chr(res, "name"),
    created = .date_helper(purrr::map_dbl(res, "created")),
    status = purrr::map_chr(res, "status"),
    time = .date_helper(purrr::map_dbl(res, "time")),
    local_date = as.Date(purrr::map_chr(res, "local_date")),
    local_time = purrr::map_chr(res, "local_time", .null = NA),
    # TO DO: Add a local_datetime combining the two above?
    waitlist_count = purrr::map_int(res, "waitlist_count"),
    yes_rsvp_count = purrr::map_int(res, "yes_rsvp_count"),
    venue_id = purrr::map_int(res, c("venue", "id"), .null = NA),
    venue_name = purrr::map_chr(res, c("venue", "name"), .null = NA),
    venue_lat = purrr::map_dbl(res, c("venue", "lat"), .null = NA),
    venue_lon = purrr::map_dbl(res, c("venue", "lon"), .null = NA),
    venue_address_1 = purrr::map_chr(res, c("venue", "address_1"), .null = NA),
    venue_city = purrr::map_chr(res, c("venue", "city"), .null = NA),
    venue_state = purrr::map_chr(res, c("venue", "state"), .null = NA),
    venue_zip = purrr::map_chr(res, c("venue", "zip"), .null = NA),
    venue_country = purrr::map_chr(res, c("venue", "country"), .null = NA),
    description = purrr::map_chr(res, c("description"), .null = NA),
    link = purrr::map_chr(res, c("link")),
    #added because of error when res is null
    resource = res
  )
}


##---------------------------------------------------------------------------------------
# new function, get_hosts() is used to extract `event_hosts` data only out of a complete event's data

get_hosts <- function(urlname, event_status = "past", fields = NULL, api_key = NULL) {
  if (!is.null(event_status) &&
      !event_status %in% c("cancelled", "draft", "past", "proposed", "suggested", "upcoming")) {
    stop(sprintf("Event status %s not allowed", event_status))
  }
  # If event_status contains multiple statuses, we can pass along a comma sep list
  if (length(event_status) > 1) {
    event_status <- paste(event_status, collapse = ",")
  }
  api_method <- paste0(urlname, "/events")
  res <- .fetch_results(api_method, api_key, event_status, fields = fields)
  #return(res)
  return(lapply(res, "[[", "event_hosts"))
}


##-----------------------------------------------------------------------------------------------
# 

get_rladies_hosts <- function(){

# To retrieve all R-Ladies groups urlname so that we can use their urlnames to get their events using lapply
meetup_api_key <- Sys.getenv("MEETUP_KEY")

# retrieve all groups
all_rladies_groups <- find_groups(text = "r-ladies", fields = "past_event_count, upcoming_event_count", api_key = meetup_api_key)

# Cleanup
rladies_groups <- all_rladies_groups[grep(pattern = "rladies|r-ladies|r ladies",  x = all_rladies_groups$name, ignore.case = TRUE), ]

past_event_counts <- purrr::map_dbl(rladies_groups$resource, "past_event_count", .default = 0)
upcoming_event_counts <- purrr::map_dbl(rladies_groups$resource, "upcoming_event_count", .default = 0)

# add a full urlname, past_events and upcoming_events as another column
rladies_groups$fullurl <- paste0("https://www.meetup.com/", rladies_groups$urlname, "/")
rladies_groups$past_events <- past_event_counts
rladies_groups$upcoming_events <- upcoming_event_counts

# order groups in descending order by past_events column, note top 10 groups
rladies_groups <- rladies_groups[order(-rladies_groups$past_events),]

#remove groups for which event_hosts are not made public, and remove groups with 0 events
restricted_groups <- c("rladies-natal", "rladies-xalapa")
rladies_groups <- rladies_groups[!(rladies_groups$past_events==0 | rladies_groups$urlname==restricted_groups),]

urlnames <- rladies_groups$urlname 

#use lapply to call the get_hosts() function for all urlnames
all_past_events <- lapply(urlnames, get_hosts, event_status = "past", fields = "event_hosts", api_key = meetup_api_key)

hostnames  <- c()
for (i in 1:length(all_past_events)) {
  for (j in 1:length( all_past_events[[i]] )) {
    for (k in 1:length( all_past_events[[i]][[j]] )) {
      hostnames <- c(all_past_events[[i]][[j]][[k]][["name"]], hostnames)
    }
  }
}

hostcount <- c()
for (i in 1:length(all_past_events)) {
  for (j in 1:length( all_past_events[[i]] )) {
    for (k in 1:length( all_past_events[[i]][[j]] )) {
      hostcount <- c(all_past_events[[i]][[j]][[k]][["host_count"]], hostcount)
    }
  }
}
hostsdf <- data.frame(hostnames, hostcount)

# remove duplicate records
uniqhosts = hostsdf[!duplicated(hostsdf$hostnames), ]

# order the records in descending order to see top hosts
uniqhosts <- uniqhosts[order(-uniqhosts$hostcount), ]

write.csv(uniqhosts, "docs/data/rladies_hosts.csv")   
}

get_rladies_hosts()