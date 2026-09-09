// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

/**
 * GPU NVMe IO helpers
 *
 * Host-side queue management and device-side helpers for submitting NVMe
 * commands from CUDA kernels using xNVMe's NVMe spec types.
 *
 * @note This API is experimental and may change without notice.
 *
 * @file libxnvme_cuda.h
 */

#ifndef __LIBXNVME_CUDA_H
#define __LIBXNVME_CUDA_H

#include <stdint.h>

#ifdef __CUDACC__
#include <errno.h>

/**
 * GPU-resident NVMe queue pair
 *
 * Instances live in CUDA device memory. Create one via xnvme_cuda_queue_create()
 * and pass the returned pointer as a kernel argument.
 *
 * With __CUDACC__ (nvcc compiling CUDA kernels):
 * the full definition is provided. This is required for xnvme_cuda_cmd_io().
 */
struct xnvme_cuda_queue {
	void *sq;         ///< VA-Pointer to DMA-capable memory backing the Submission Queue (SQ)
	void *cq;         ///< VA-Pointer to DMA-capable memory backing the Completion Queue (CQ)
	void *sqdb;       ///< Pointer to Submission Queue Doorbell Register in bar0
	void *cqdb;       ///< Pointer to Completion Queue Doorbell Register in bar0
	uint32_t qid;     ///< The admin: queue-id == 0 ; io: queue-id > 0;
	uint16_t depth;   ///< Length of the queue-pair
	uint16_t tail;    ///< Submission Queue Tail Pointer
	uint16_t head;    ///< Completion Queue Head Pointer
	uint8_t phase;    ///< Expected CQ phase bit; flips each time the CQ head wraps to 0
	uint8_t _rsvd[3]; ///< Padding to align timeout_ms to a 4-byte boundary
	uint32_t timeout_ms;    ///< Command timeout in milliseconds (derived from cap.to)
	uint64_t clocks_per_ms; ///< SM clock cycles per millisecond (set from
				///< CU_DEVICE_ATTRIBUTE_CLOCK_RATE)
};
#else
/**
 * Opaque GPU-resident NVMe queue pair
 *
 * Instances live in CUDA device memory. Create one via xnvme_cuda_queue_create()
 * and pass the returned pointer as a kernel argument.
 *
 * Without __CUDACC__ (host C/C++ callers):
 * only a forward declaration is visible
 */
struct xnvme_cuda_queue;
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Create a GPU-resident NVMe IO queue
 *
 * Allocates a queue pair in CUDA device memory and registers it with the NVMe
 * controller. The resulting pointer lives in device memory and can be passed
 * directly as a CUDA kernel argument.
 *
 * @param dev   An xnvme_dev opened on an ``upcie-cuda`` device
 * @param depth Number of IO slots in the queue
 * @param queue On success, set to a device pointer to the GPU queue
 *
 * @return 0 on success, negative error code on failure
 */
int
xnvme_cuda_queue_create(struct xnvme_dev *dev, uint16_t depth, struct xnvme_cuda_queue **queue);

/**
 * Destroy a GPU-resident NVMe IO queue
 *
 * Deletes the queue pair from the NVMe controller and frees the device memory.
 *
 * @param dev   The xnvme_dev used to create the queue
 * @param queue GPU queue pointer returned by xnvme_cuda_queue_create()
 */
void
xnvme_cuda_queue_destroy(struct xnvme_dev *dev, struct xnvme_cuda_queue *queue);

#ifdef __CUDACC__

/**
 * Enqueue a command into an NVMe submission queue at a certain index
 *
 * That is, writes it into the submission queue memory. It does **not** increment
 * the tail-pointer or write the tail to the sq-doorbell.
 *
 * @param qp Pointer to the NVMe queue pair to submit command to
 * @param cmd Command to submit
 * @param offset Where to insert the Command in the queue in relation to the tail
 */
static inline __device__ void
xnvme_cuda_enqueue_at_i(struct xnvme_cuda_queue *qp, struct xnvme_spec_cmd *cmd, uint16_t offset)
{
	struct xnvme_spec_cmd *sq = (struct xnvme_spec_cmd *)qp->sq;
	uint16_t index            = (qp->tail + offset) % qp->depth;

	// The queue is in host memory, so store width is writes across the link.
	// The source is read narrow: a per-thread local is not 16-byte aligned.
	const uint32_t *src = (const uint32_t *)cmd;
	uint4 *dst          = (uint4 *)&sq[index];

	for (unsigned i = 0; i < sizeof(struct xnvme_spec_cmd) / sizeof(uint4); i++) {
		uint4 quad;

		quad.x = src[i * 4 + 0];
		quad.y = src[i * 4 + 1];
		quad.z = src[i * 4 + 2];
		quad.w = src[i * 4 + 3];

		__stwt(&dst[i], quad);
	}
}

/**
 * Update the submission queue tail and tail doorbell
 *
 * This function updates the tail and writes it to the MMIO doorbell register
 * for the given queue pair, notifying the controller of new commands.
 *
 * @param qp Pointer to the NVMe queue pair whose SQ doorbell should be updated.
 * @param increment Number of commands to increment the tail by
 */
static inline __device__ void
xnvme_cuda_sq_update(struct xnvme_cuda_queue *qp, uint16_t increment)
{
	const uint16_t last        = (uint16_t)((qp->tail + increment - 1) % qp->depth);
	volatile uint32_t *written = (volatile uint32_t *)&((struct xnvme_spec_cmd *)qp->sq)[last];

	qp->tail = (qp->tail + increment) % qp->depth;

	__threadfence_system(); // flush sq writes to system DRAM (visible to NVMe DMA)

	/* PCIe orders posted writes per destination, so the doorbell can beat the
	 * entries to the controller; reading one back pushes them out first. */
	(void)*written;

	__threadfence_system();

	*(volatile uint32_t *)qp->sqdb = qp->tail;
}

/**
 * Reaps the completion queue entry at a certain index if ready before timeout
 *
 * This function does **not** increment the head-pointer or write the head to the
 * cq-doorbell.
 *
 * @param qp Pointer to the NVMe queue pair to reap completion from
 * @param timeout_ms Timeout in milliseconds
 * @param cpl Completion when one is reaped, NULL if timeout
 * @param offset Which completion to reap in relation to the head
 *
 * @return 0 on success, -EAGAIN on timeout
 */
static inline __device__ int
xnvme_cuda_reap_at_i(struct xnvme_cuda_queue *qp, int timeout_ms, struct xnvme_spec_cpl *cpl,
		     uint16_t offset)
{
	volatile struct xnvme_spec_cpl *cq = (volatile struct xnvme_spec_cpl *)qp->cq;
	uint16_t index                     = (qp->head + offset) % qp->depth;
	volatile struct xnvme_spec_cpl *cqe;
	// If this thread's entry is past the CQ wrap point, the controller will
	// have already flipped its phase tag for that entry.
	uint8_t expected_phase =
		((uint16_t)(qp->head + offset) >= qp->depth) ? (qp->phase ^ 1) : qp->phase;

	int64_t deadline = (int64_t)clock64() + (int64_t)timeout_ms * (int64_t)qp->clocks_per_ms;

	do {
		cqe = &cq[index];

		if ((cqe->cid < 0xFFFF) && (cqe->status.p == expected_phase)) {
			*cpl = *(struct xnvme_spec_cpl *)cqe;
			return 0;
		}
	} while ((int64_t)clock64() < deadline);

	return -EAGAIN;
}

/**
 * Reap whatever completions the queue holds, as a run from the head
 *
 * The block reads one entry per thread from the head onwards and takes the run
 * of them carrying the awaited phase, so what a call reaps is what has arrived
 * rather than a count decided beforehand. That is what lets a queue be kept
 * full: the slots a call frees are the ones to refill, and the rest stay in
 * flight, where reaping a fixed count means waiting for the slowest of them
 * with the queue draining behind it.
 *
 * The run has to be unbroken from the head, since the head is what the
 * controller is told has been consumed; a completion sitting past a gap is left
 * for the call that reaches it.
 *
 * Every thread of the block must call this and the return is the same in all of
 * them. Thread `tid` holds the tid'th completion of the run when tid < the
 * return, and its `cid` says which command it belongs to -- completions arrive
 * in whatever order the controller finishes, not the order they were submitted,
 * so the position a completion is read at says nothing about which command it
 * is for.
 *
 * Does **not** advance the head or ring the doorbell; see xnvme_cuda_cq_update().
 *
 * @param qp Pointer to the NVMe queue pair to reap completions from
 * @param tid The id of the thread calling the function (threadIdx.x)
 * @param cpl Filled for tid < the returned count
 * @param scratch Shared memory of at least blockDim.x / 32 + 1 uint32_t, the
 *                same address in every thread
 *
 * @return Number of completions ready as a run from the head, 0 when none are
 */
static inline __device__ uint32_t
xnvme_cuda_reap_ready(struct xnvme_cuda_queue *qp, size_t tid, struct xnvme_spec_cpl *cpl,
		      uint32_t *scratch)
{
	const uint4 *cq       = (const uint4 *)qp->cq;
	const uint32_t nwarps = (uint32_t)((blockDim.x + 31) / 32);
	const uint32_t warp   = (uint32_t)(tid >> 5);
	const uint32_t lane   = (uint32_t)(tid & 31);
	uint32_t index        = qp->head + (uint32_t)tid;
	uint32_t expected     = qp->phase;
	uint4 entry;
	unsigned mask;
	uint32_t n;

	/* A block never reads further than the ring is long, so an index runs past
	 * the end at most once, and the entries past it carry the flipped tag. */
	if (index >= qp->depth) {
		index -= qp->depth;
		expected ^= 1u;
	}

	entry = __ldcv(&cq[index]);

	mask = __ballot_sync(0xffffffffu, ((entry.w >> 16) & 1u) == expected);
	if (!lane) {
		scratch[warp] = (mask == 0xffffffffu) ? 32u : (uint32_t)(__ffs((int)~mask) - 1);
	}

	__syncthreads();

	/* A warp only adds to the run when every warp before it was full. */
	if (!tid) {
		uint32_t total = 0;

		for (uint32_t w = 0; w < nwarps; ++w) {
			total += scratch[w];
			if (scratch[w] < 32u) {
				break;
			}
		}
		scratch[nwarps] = total;
	}

	__syncthreads();

	n = scratch[nwarps];

	if (tid < n) {
		uint32_t *dst = (uint32_t *)cpl;

		dst[0] = entry.x;
		dst[1] = entry.y;
		dst[2] = entry.z;
		dst[3] = entry.w;
	}

	return n;
}

/**
 * Update the completion queue head and head doorbell
 *
 * This function updates the head and writes it to the MMIO doorbell register
 * for the given queue pair, notifying the controller that all completions have
 * been reaped.
 *
 * @param qp Pointer to the NVMe queue pair whose CQ doorbell should be updated.
 * @param increment Number of commands to increment the head by
 */
static inline __device__ void
xnvme_cuda_cq_update(struct xnvme_cuda_queue *qp, uint16_t increment)
{
	uint16_t new_head = qp->head + increment;

	if (new_head >= qp->depth) {
		new_head -= qp->depth;
		qp->phase ^= 1;
	}
	qp->head                       = new_head;
	*(volatile uint32_t *)qp->cqdb = qp->head;
}

/**
 * Submit an NVMe command and reap its completion from a CUDA kernel
 *
 * The intention is to use this in a CUDA kernel where the threadblock size is
 * equal to the queue depth and the number of threadblocks is equal to the number
 * of queues.
 *
 * The function works as follows:
 *   1) Each active thread (tid < batch_size) enqueues its command with
 *      `xnvme_cuda_enqueue_at_i()` where offset == thread index
 *   2) A threadblock barrier ensures all commands are written before continuing
 *   3) **Only** the first thread in the block calls
 *      `xnvme_cuda_sq_update()` with increment == batch_size
 *   4) Each active thread reaps a completion with `xnvme_cuda_reap_at_i()`
 *      where offset == thread index
 *   5) A threadblock barrier ensures all completions are reaped before continuing
 *   6) **Only** the first thread in the block calls `xnvme_cuda_cq_update()`
 *      with increment == batch_size
 *
 * Inactive threads (tid >= batch_size) participate in the barriers but do not
 * submit or reap commands and return 0. This allows partial rounds where fewer
 * than blockDim.x IOs are needed without breaking the collective barrier contract.
 *
 * The barriers in steps 2 and 5 are required for correct operation when the
 * threadblock spans multiple warps (i.e. batch_size > 32). Without them, thread 0
 * may ring the SQ doorbell before other warps have written their commands, or
 * advance the CQ head and flip the phase before other warps have reaped.
 *
 * @param qp         GPU queue pair (from xnvme_cuda_queue_create())
 * @param cmd        Command to submit (only read for tid < batch_size)
 * @param tid        Thread index within the block (threadIdx.x)
 * @param batch_size Number of IOs to submit; threads with tid >= batch_size
 *                   participate in barriers but do not submit or reap
 *
 * @return 0 on success. -EAGAIN on completion timeout. Positive NVMe status
 *         code on device error.
 */
static inline __device__ int
xnvme_cuda_cmd_io(struct xnvme_cuda_queue *qp, struct xnvme_spec_cmd *cmd, size_t tid,
		  size_t batch_size)
{
	struct xnvme_spec_cpl cpl = {0};
	int err                   = 0;

	if (tid < batch_size) {
		cmd->common.cid = tid;
		xnvme_cuda_enqueue_at_i(qp, cmd, tid);
	}

	__syncthreads();

	if (tid == 0 && batch_size) {
		xnvme_cuda_sq_update(qp, batch_size);
	}

	if (tid < batch_size) {
		err = xnvme_cuda_reap_at_i(qp, qp->timeout_ms, &cpl, tid);
	}

	__syncthreads();

	if (tid == 0 && batch_size) {
		xnvme_cuda_cq_update(qp, batch_size);
	}

	if (err) {
		return err;
	}

	return cpl.status.sc;
}

#endif /* __CUDACC__ */

#ifdef __cplusplus
}
#endif

#endif /* __LIBXNVME_CUDA_H */
