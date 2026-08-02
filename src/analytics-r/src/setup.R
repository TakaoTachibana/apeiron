required_packages <- c("Rcpp", "TDA", "jsonlite")

for (pkg in required_packages) {
	if (!requireNamespace(pkg, quietly = TRUE)) {
		message(paste("[R Setup] installing missing package:", pkg))
		install.packages(pkg, repos = "http://cloud.r-project.org")
	}
}

message("[R Setup] All dependencies (Rcpp, TDA, jsonlite) are ready!")

