// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

#include <libxnvme.h>
#include <errno.h>
#ifdef XNVME_BE_UPCIE_CUDA_ENABLED
#include <string.h>
#include <xnvme_dev.h>
#include <xnvme_be_upcie_cuda.h>

int
xnvme_cuda_queue_create(struct xnvme_dev *dev, uint16_t depth, struct xnvme_cuda_queue **queue)
{
	struct xnvme_be_upcie_state *state = (void *)dev->be.state;
	struct dmamem_heap *host_heap = &g_upcie_rte.mem.heap;
	struct xnvme_cuda_queue *qpair;
	size_t sq_nbytes, sq_offset;
	void *sq_host, *sq_dev;
	uint64_t sq_iova;
	int err;

	/* The queue is created one entry longer than asked for, below. */
	sq_nbytes = (size_t)(depth + 1) * sizeof(struct xnvme_spec_cmd);

	err = dmamem_heap_alloc_array_aligned(host_heap, 1, sq_nbytes, 4096, &sq_offset);
	if (err) {
		XNVME_DEBUG("FAILED: dmamem_heap_alloc_array_aligned(sq); err(%d)", err);
		return err;
	}

	sq_host = dmamem_heap_at_va(host_heap, sq_offset);
	sq_iova = dmamem_heap_at_iova(host_heap, sq_offset);
	if (!sq_host || !sq_iova) {
		XNVME_DEBUG("FAILED: the submission queue has no address to reach it by");
		dmamem_heap_free(host_heap, sq_offset);
		return -EFAULT;
	}

	/* The heap does not clear what it hands out, and a stale entry reads as a
	 * command. */
	memset(sq_host, 0, sq_nbytes);

	sq_dev = (void *)(uintptr_t)(g_upcie_cuda_rte.host_devptr +
				     ((char *)sq_host - (char *)g_upcie_cuda_rte.host_va));

	err = cuMemAlloc((CUdeviceptr *)&qpair, sizeof(struct xnvme_cuda_queue));
	if (err) {
		XNVME_DEBUG("FAILED: cuMemAlloc(qpair); CUresult(%d)", err);
		dmamem_heap_free(host_heap, sq_offset);
		return -ENOMEM;
	}

	err = xnvme_be_upcie_mproc_qids_lock(state->ctrlr);
	if (err) {
		XNVME_DEBUG("FAILED: xnvme_be_upcie_mproc_qids_lock(); err(%d)", err);
		cuMemFree((CUdeviceptr)qpair);
		dmamem_heap_free(host_heap, sq_offset);
		return err;
	}

	// The spec says that for systems where memory ordering is not guaranteed, then one should
	// leave room in the queue to avoid races. Thus, we do so here, by allocating one more than
	// what is needed.
	err = nvme_controller_cuda_create_io_qpair(
		state->ctrlr->ctrl, (struct nvme_qpair_cuda *)qpair, depth + 1,
		&g_upcie_cuda_rte.cuda_heap, state->dmem, sq_dev, sq_iova);

	xnvme_be_upcie_mproc_qids_unlock(state->ctrlr);

	if (err) {
		XNVME_DEBUG("FAILED: nvme_controller_cuda_create_io_qpair(); err(%d)", err);
		cuMemFree((CUdeviceptr)qpair);
		dmamem_heap_free(host_heap, sq_offset);
		return -err;
	}

	*queue = qpair;
	return 0;
}

void
xnvme_cuda_queue_destroy(struct xnvme_dev *dev, struct xnvme_cuda_queue *queue)
{
	struct xnvme_be_upcie_state *state = (void *)dev->be.state;
	struct nvme_qpair_cuda _qpair = {0};
	size_t sq_offset = 0;
	int have_sq = 0;
	int err;

	/* Read while the queue still describes where its submission queue is; the
	 * heap offset it was carved at is that far into the window. */
	err = cuMemcpyDtoH(&_qpair, (CUdeviceptr)queue, sizeof(_qpair));
	if (err) {
		XNVME_DEBUG("FAILED: cuMemcpyDtoH(qpair); CUresult(%d)", err);
	} else {
		sq_offset =
			(size_t)((CUdeviceptr)(uintptr_t)_qpair.sq - g_upcie_cuda_rte.host_devptr);
		have_sq = 1;
	}

	err = xnvme_be_upcie_mproc_qids_lock(state->ctrlr);
	if (err) {
		// Without the admin queue the device-side queues cannot be deleted, and
		// releasing the GPU memory they still reference would be worse than leaking it.
		XNVME_DEBUG("FAILED: xnvme_be_upcie_mproc_qids_lock(); err(%d)", err);
		return;
	}

	nvme_controller_cuda_delete_io_qpair(state->ctrlr->ctrl, (struct nvme_qpair_cuda *)queue,
					     &g_upcie_cuda_rte.cuda_heap, 0);

	xnvme_be_upcie_mproc_qids_unlock(state->ctrlr);

	if (have_sq) {
		dmamem_heap_free(&g_upcie_rte.mem.heap, sq_offset);
	}

	cuMemFree((CUdeviceptr)queue);
}

#else

int
xnvme_cuda_queue_create(struct xnvme_dev *XNVME_UNUSED(dev), uint16_t XNVME_UNUSED(depth),
			struct xnvme_cuda_queue **XNVME_UNUSED(queue))
{
	return -ENOSYS;
}

void
xnvme_cuda_queue_destroy(struct xnvme_dev *XNVME_UNUSED(dev),
			 struct xnvme_cuda_queue *XNVME_UNUSED(queue))
{
}

#endif
