// SPDX-License-Identifier: BSD-3-Clause


/**
 * CUDA NVMe Request Extension
 * ===========================
 *
 * This header extends the functionality defined in the uPCIe NVMe Request header
 * `upcie/nvme/nvme_request.h` with a CUDA dependent PRP preparation function.
 */

/**
 * Prepare the PRP list for a command with a contiguous CUDA data buffer.
 *
 * This function initializes the Physical Region Page (PRP) entries in the given NVMe command
 * (`cmd`) using the provided request and a contiguous data buffer (in VA-space).
 * It sets up the PRP1 and PRP2 fields in the command to describe the physical memory backing the
 * `data` buffer, allowing the NVMe controller to access the buffer during command execution.
 *
 * Caveats
 * -------
 *
 * - `dbuf` need not be physically contiguous; every PRP entry is translated via
 *   `cudamem_heap_block_vtp()`, so buffers may span physically scattered device pages.
 * - Does *not* support PRP list chaining; only a single list page is constructed.
 *
 * @param request Pointer to the NVMe request context used for tracking and metadata.
 * @param heap Pointer to the CUDA memory heap that dbuf is allocated within.
 * @param dbuf Pointer to the contiguous data buffer to be described by PRPs.
 * @param dbuf_nbytes Size in bytes of the data buffer.
 * @param cmd Pointer to the NVMe command to be prepared with PRP entries.
 */
static inline void
nvme_request_prep_command_prps_contig_cuda(struct nvme_request *request, struct cudamem_heap *heap,
                                           void *dbuf, size_t dbuf_nbytes, struct nvme_command *cmd)
{
	const uint64_t pagesize = heap->config->pagesize;

	/* Only PRP1 may carry a sub-page offset; the page count and every later
	 * entry are measured from the page floor. ceil((off+nbytes)/pagesize).
	 * Entries are translated individually — the heap is virtually contiguous
	 * but physically contiguous only within a device page. The sub-page offset
	 * is identical for the virtual and translated address, so take it from
	 * `dbuf` to keep the page count (and the single-page early-out below) off
	 * the vtp() load's dependency chain — the hot path for small I/O. */
	const uint64_t page_off = (uintptr_t)dbuf & (pagesize - 1);
	uint8_t *vbase = (uint8_t *)dbuf - page_off;
	const uint64_t npages =
		(page_off + dbuf_nbytes + pagesize - 1) >> heap->config->pagesize_shift;

	cmd->prp1 = cudamem_heap_block_vtp(heap, dbuf);

	/* Chaining is not supported, thus assert that the given dbuf fits. */
	assert(npages <= 1 + 512);

	if (npages == 1) {
		return;
	} else if (npages == 2) {
		cmd->prp2 = cudamem_heap_block_vtp(heap, vbase + pagesize);
	} else {
		uint64_t *prp_list = (uint64_t *)request->prp;

		cmd->prp2 = request->prp_addr;
		for (uint64_t i = 1; i < npages; ++i) {
			prp_list[i - 1] = cudamem_heap_block_vtp(heap, vbase + i * pagesize);
		}
	}
}

/**
 * Prepare the PRP list for a command with a CUDA iovec (scatter-gather) data buffer.
 *
 * This function initializes the Physical Region Page (PRP) entries in the given NVMe command
 * (`cmd`) using the provided request and an array of iovec entries. Each iovec entry is assumed to
 * be page-aligned and allocated from the given `heap`.
 *
 * Caveats
 * -------
 *
 * - Each iovec base must be page-aligned and allocated from `heap`.
 * - Does *not* support PRP list chaining; only a single list page is constructed.
 *
 * @param request Pointer to the NVMe request context used for tracking and metadata.
 * @param heap Pointer to the CUDA heap that iovec buffers are allocated within.
 * @param dvec Array of iovec structures describing the data segments.
 * @param dvec_cnt Number of elements in the dvec array.
 * @param cmd Pointer to the NVMe command to be prepared with PRP entries.
 */
static inline void
nvme_request_prep_command_prps_iov_cuda(struct nvme_request *request, struct cudamem_heap *heap,
				   	struct iovec *dvec, size_t dvec_cnt, struct nvme_command *cmd)
{
	const uint64_t pagesize = heap->config->pagesize;
	uint64_t *prp_list = (uint64_t *)request->prp;
	size_t prp_idx = 0;

	cmd->prp1 = cudamem_heap_block_vtp(heap, dvec[0].iov_base);

	for (size_t i = 0; i < dvec_cnt; ++i) {
		uint8_t *base = (uint8_t *)dvec[i].iov_base;
		size_t remaining = dvec[i].iov_len;
		size_t offset = 0;

		/* Skip the first page of the first iovec — it is PRP1 */
		if (i == 0) {
			offset = pagesize;
			remaining = (remaining > pagesize) ? remaining - pagesize : 0;
		}

		while (remaining > 0) {
			prp_list[prp_idx++] = cudamem_heap_block_vtp(heap, base + offset);

			offset += pagesize;
			remaining = (remaining > pagesize) ? remaining - pagesize : 0;
		}
	}

	if (prp_idx == 1) {
		cmd->prp2 = prp_list[0];
	} else if (prp_idx > 1) {
		cmd->prp2 = request->prp_addr;
	}
}
