source("setup.R")

library(Rcpp)
library(TDA)
library(jsonlite)

sourceCpp(code = '
#include <sys/ipc.h>
#include <sys/shm.h>
#include <cstdint>
#include <vector>
#include <algorithm>
#include <Rcpp.h>

struct SharedMemoryHeader {
	uint32_t magic;
	uint32_t _pad;
	uint64_t write_index;
	uint64_t read_index_r;
	uint64_t read_index_j;
	uint32_t flag_tda_disruption;
	uint32_t flag_sindy_updated;
	uint8_t _reserved[24];
};

const uint64_t DATA_OFFSET = 64;
const uint64_t SHM_SIZE = 128 * 1024 * 1024;
const uint64_t RING_SIZE = SHM_SIZE - DATA_OFFSET;

inline uint8_t safe_read_byte(const char* shm_buf, uint64_t abs_pos) {
	uint64_t rel_pos = abs_pos % RING_SIZE;
	return static_cast<uint8_t>(shm_buf[DATA_OFFSET + rel_pos]);
}

inline uint32_t safe_read_uint32(const char* shm_buf, uint64_t abs_pos) {
	uint32_t b1 = safe_read_byte(shm_buf, abs_pos);
	uint32_t b2 = safe_read_byte(shm_buf, abs_pos + 1);
	uint32_t b3 = safe_read_byte(shm_buf, abs_pos + 2);
	uint32_t b4 = safe_read_byte(shm_buf, abs_pos + 3);
	return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24);
}


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
	Rcpp::XPtr<SharedMemoryHeader> header(xp);
	return Rcpp::List::create(
		Rcpp::Named("magic") = header->magic,
		Rcpp::Named("write_index") = (double)header->write_index,
		Rcpp::Named("read_index_r") = (double)header->read_index_r
	);
}

// [[Rcpp::export]]
void set_shm_disruption_flag_cpp(SEXP xp, int flag_value) {
	Rcpp::XPtr<SharedMemoryHeader> header(xp);
	header->flag_tda_disruption = static_cast<uint32_t>(flag_value);
}

// [[Rcpp::export]]
Rcpp::List read_shm_timeseries_cpp(SEXP xp, int window_size) {
	Rcpp::XPtr<SharedMemoryHeader> header(xp);
	uint64_t write_idx = header->write_index;
	uint64_t last_read_pos = header->read_index_r;

	if (last_read_pos < DATA_OFFSET) {
		last_read_pos = DATA_OFFSET;
	}

	uint64_t curr_pos = last_read_pos;
	if (write_idx > curr_pos + 1024 * 1024) {
		curr_pos = write_idx - 1024 * 1024;
	}

	const char* shm_buf = reinterpret_cast<const char*>(header.get());
	std::vector<double> features;
	features.reserve(1000);

	while (curr_pos + 4 < write_idx && features.size() < 1000) {
		uint32_t pkt_len = safe_read_uint32(shm_buf, curr_pos);

		if (pkt_len > 0 && pkt_len < 65536 && (curr_pos + 4 + pkt_len <= write_idx)) {
			features.push_back(static_cast<double>(pkt_len));
			curr_pos += (4 + pkt_len);
		} else {
			curr_pos += 1;
		}
	}

	header->read_index_r = curr_pos;

	if (features.size() < 20) {
		return Rcpp::List::create(
			Rcpp::Named("vec") = Rcpp::NumericVector(0),
			Rcpp::Named("valid") = false
		);
	}

	int N = std::min(static_cast<int>(features.size()), window_size);
	Rcpp::NumericVector vec(N);
	size_t start_feat = features.size() - N;
	for (int i = 0; i < N; i++) {
		vec[i] = features[start_feat + i];
	}

	return Rcpp::List::create(
			Rcpp::Named("vec") = vec,
			Rcpp::Named("valid") = true
	);
}

// [[Rcpp::export]]
double get_shm_write_index_cpp(SEXP xp) {
	Rcpp::XPtr<SharedMemoryHeader> header(xp);
	return (double)header->write_index;
}
')

SHM_KEY <- 0x41504549
SHM_SIZE <- 128 * 1024 * 1024

run_tda_pipeline <- function(time_series, m = 3, tau = 2, maxscale = 2.5) {
	std_val <- sd(time_series)
	if (is.na(std_val) || std_val < 1e-6) {
		return(list(max_persistence = 0.0, disruption = FALSE))
	}
	ts_scaled <- (time_series - mean(time_series)) / std_val

	embedded_matrix <- embed(ts_scaled, dimension = m)

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

		if (max_persistence > 0.35) {
			disruption_flag <- TRUE
		}
	}

	return(list(
		max_persistence = max_persistence,
		disruption = disruption_flag
	))
}

main <- function() {
	cat("=== A P E I R O N // Analytics Engine (R) ===\n")

	shm_xp <- attach_shm_cpp(SHM_KEY, SHM_SIZE)
	header <- read_shm_header_cpp(shm_xp)

	if (header$magic != SHM_KEY) {
		stop("[R Analytics] Invalid Shard Memory Header Magic Byte!")
	}

	cat("[R Analytics] Attached Shared Memory (Magic: APEI)\n")
	cat("[R Analytics] Direct Pointer Polling for TDA Persistence Diagrams...\n")

	last_write_idx <- 0

	while (TRUE) {
		current_write_idx <- get_shm_write_index_cpp(shm_xp)
		
		if (current_write_idx > last_write_idx) {
			res_data <- read_shm_timeseries_cpp(shm_xp, 100)
			if (isTRUE(res_data$valid)) {
				res <- run_tda_pipeline(res_data$vec)

				cat(sprintf("\n[TDA Real-Time SHM Analysis | Write Index: %.0f]\n", current_write_idx))
				cat(sprintf("  Max 1-Cycle Persistence (H1): %.4f\n", res$max_persistence))

				if (res$disruption) {
					cat("  Topological Disruption Signal: CRITICAL (Meta-Rewrite Triggered -> Signaling Julia)\n")
					set_shm_disruption_flag_cpp(shm_xp, 1)
				} else {
					cat(sprintf("  Topological Disruption Signal: %s\n", ifelse(res$disruption, "CRITICAL (Meta-Rewrite Triggered)", "STABLE")))
				}
			}

			last_write_idx <- current_write_idx
		}
		Sys.sleep(2)
	}
}

main()


