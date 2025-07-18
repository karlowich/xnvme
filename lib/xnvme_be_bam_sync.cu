// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

int
xnvme_be_bam_sync_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)ctx->dev->be.state;
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)state->sync_q;
	uint32_t cmd_id = ((struct xnvme_cmd_ctx_entry *)ctx)->id;
	struct xnvme_spec_cpl *cpl;
	struct xnvme_be_bam_memory *m;
	nvm_cmd_t *cmd;
	nvm_dma_t *mem;
	int err;
	uint64_t offset;
	size_t n_pages;
	uint16_t prp_list;

	ctx->cmd.common.cid = cmd_id;
	cmd = nvm_sq_enqueue(queue->sq);
	if (!cmd) {
		XNVME_DEBUG("FAILED: couldn't get cmd entry");
		return -EBUSY;
	}
	*cmd = *((nvm_cmd_t *)&ctx->cmd);

	if (dbuf) {
		m = xnvme_be_bam_memory_find(state, dbuf);
		if (!m) {
			XNVME_DEBUG("FAILED: couldn't find memory in skiplist");
			return -ENOENT;
		}
		mem = m->mem;

		prp_list = (cmd_id % queue->sq->qs) + 1;
		offset = ((uint64_t)dbuf - (uint64_t)mem->vaddr) / mem->page_size;

		n_pages = dbuf_nbytes / mem->page_size;
		nvm_cmd_data1(cmd, mem->page_size, n_pages, NVM_DMA_OFFSET(queue->sq_mem, prp_list),
			queue->sq_mem->ioaddrs[prp_list], &mem->ioaddrs[offset]);
	}

	nvm_sq_submit(queue->sq);

	do {
		cpl = (struct xnvme_spec_cpl *)nvm_cq_dequeue(queue->cq);
	} while (!cpl);

	nvm_sq_update(queue->sq);

	memcpy(&ctx->cpl, cpl, sizeof(ctx->cpl));
	nvm_cq_update(queue->cq);

	if (xnvme_cmd_ctx_cpl_status(ctx)) {
		XNVME_DEBUG("FAILED: xnvme_cmd_ctx_cpl_status(), sct: %d, sc: %d", ctx->cpl.status.sct, ctx->cpl.status.sc);
		return -EIO;
	}

	return 0;
}

__device__ int
xnvme_be_bam_gpu_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)ctx->dev->be.state;
	struct xnvme_be_bam_memory *m;
	nvm_queue_t *sq, *cq;
	nvm_cmd_t *cmd;
	uint64_t *ioaddrs;
	uint32_t pos, qid, cid, head, head_;
	uint64_t offset, remainder, prp1, prp2 = 0;

	if (lane_id() == 0) {
		qid = state->queue_counter.fetch_add(1, simt::memory_order_relaxed) % state->n_qps;
	}
	qid = __shfl_sync(0xFFFFFFFF, qid, 0);

	sq = &state->sq[qid];
	cq = &state->cq[qid];

	cid = get_cid(sq);
	ctx->cmd.common.cid = cid;
	cmd = (nvm_cmd_t *) &ctx->cmd;

	if (dbuf) {
		m = xnvme_be_bam_memory_find(state, dbuf);
		if (!m) {
			return -ENOENT;
		}

		if (dbuf_nbytes > state->ctrlr->page_size * 2) {
			return -EINVAL;
		}

		offset = ((uint64_t)dbuf - (uint64_t)m->mem->vaddr)/m->mem->page_size;
		remainder = (((uint64_t)dbuf - (uint64_t)m->mem->vaddr)%m->mem->page_size);
		ioaddrs = m->mem->ioaddrs;
		prp1 = ioaddrs[offset] + remainder;

		if (dbuf_nbytes > m->mem->page_size) {
			prp2 = prp1 + m->mem->page_size;
		}

		nvm_cmd_data_ptr(cmd, prp1, prp2);
	}

	sq_enqueue(sq, cmd);
	pos = cq_poll(cq, cid, &head, &head_);
	cq_dequeue(cq, pos, sq);
	put_cid(sq, cid);

	return 0;
}

#endif

struct xnvme_be_sync g_xnvme_be_bam_sync = {
#ifdef XNVME_BE_BAM_ENABLED
	.cmd_io = xnvme_be_bam_sync_cmd_io,
	.cmd_iov = xnvme_be_nosys_sync_cmd_iov,
#else
	.cmd_io = xnvme_be_nosys_sync_cmd_io,
	.cmd_iov = xnvme_be_nosys_sync_cmd_iov,
#endif
	.id = "bam",
};
