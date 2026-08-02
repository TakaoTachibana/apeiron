source("setup.R")

library(Rcpp)
library(TDA)
library(jsonlite)

sourceCpp(code = '
#include <sys/ipc.h>
#include <sys/shm.h>
#include <cstdint>
#include <Rcpp.h>

struct SharedMemoryHeader {
	uint32_t magic;
	uint32_t _pad;
	uint64_t write_index;
	uint64_t read_index_r;
	uint64_t read_index_j;
};

// [[Rcpp::export]]
SEXP attach_shm_cpp(int key, int size) {
	int shmid = shmget((key_t)key, (size_t)size, 0);
	if (shmid < 0) {
		Rcpp::stop("[R Analytics] Failed to find System V Shared Memory. Is Go Ingestion running?");
	}
	void* ptr = shmat(shmid, NULL, 0);
	if (ptr == (void*)-1) {
		Rcpp::stop("[R analytics] Failed to attach Shared memory segment.");
	}
	SharedMemoryHeader* header_ptr = static_cast<SharedMemoryHeader*>(ptr);
	return Rcpp::XPtr<SharedMemoryHeader>(header_ptr, false);
}

// [[Rcpp::export]]
Rcpp::List read_shm_header_cpp(SEXP xp) {
	Rcpp::XPtr<SharedMemoryHeader> ptr(xp);
	SharedMemoryHeader* header = static_cast<SharedMemoryHeader*>(ptr.get());

	return Rcpp::List::create(
		Rcpp::Named("magic") = header->magic,
		Rcpp::Named("write_index") = (double)header->write_index
	);
}
')

SHM_KEY <- 0x41504549
SHM_SIZE <- 128 * 1024 * 1024

run_tda_pipeline <- function(time_series, m = 3, tau = 1, maxscale = 2.0) {
	embedded_matrix <- embed(time_series, dimension = m)

	diag <- ripsDiag(
		X = embedded_matrix,
		maxdimension = 1,
		maxscale = maxscale,
		library = "GUDHI",
		printProgress = FALSE
	)

	diagram <- diag$diagram

	h1_features <- diagram[diagram[, "dimension"] == 1, , drop = FALSE]

	disruption_flag <- FALSE
	max_persistence <- 0.0

	if (nrow(h1_features) > 0) {
		persistence <- h1_features[, "Death"] - h1_features[, "Birth"]
		max_persistence <- max(persistence)

		if (max_persistence > 0.4) {
			disruption_flag <- TRUE
		}
	}

	return(list(
		max_persistence = max_persistence,
		disruption = disruption_flag
	))
}

main <- function() {
	cat("=== A P E I R O N // Analytics Engin (R) ===\n")

	shm_xp <- attach_shm_cpp(SHM_KEY, SHM_SIZE)
	header <- read_shm_header_cpp(shm_xp)

	if (header$magic != SHM_KEY) {
		stop("[R Analytics] Invalid Shard Memory Header Magic Byte!")
	}

	cat("[R Analytics] Attached Shared Memory (Magic: APEI)\n")
	cat("[R Analytics] Polling state space for TDA Persistence Diagmam & Homology Disruptions...\n")

	while (TRUE) {
		t <- seq(0, 4 * pi, length.out = 100)
		time_series <- sin(t) * rnorm(100, mean = 0, sd = 0.05)

		res <- run_tda_pipeline(time_series)

		cat(sprintf("\n[TDA Persistence Analysis]\n"))
		cat(sprintf("  Max 1-Cycle Persistence (H1): %.4f\n", res$max_persistence))
		cat(sprintf("  Topological Disruption Sinal: %s\n", ifelse(res$disruption, "CRITICAL (Meta-Rewirte Triggered)", "STABLE")))

		Sys.sleep(5)
	}
}

main()




