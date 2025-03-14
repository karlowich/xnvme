// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <libxnvme.h>
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <xnvme_dev.h>
#include <xnvme_queue.h>
#include <xnvme_be_bam.h>

struct xnvme_queue_bam {
	struct xnvme_queue_base base;

	nvm_queue_t *sq;
	nvm_queue_t *cq;
	nvm_dma_t *cq_mem;
	nvm_dma_t *sq_mem;

	uint8_t _rsvd[200];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_queue_bam) == XNVME_BE_QUEUE_STATE_NBYTES,
		    "Incorrect size")

int
xnvme_be_bam_queue_init(struct xnvme_queue *q, int XNVME_UNUSED(opts))
{
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)q;
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)queue->base.dev->be.state;
	int err, qid = ++state->qid;
	void *cq_buf, *sq_buf;

	err = posix_memalign(&cq_buf, 4096, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}

	err = nvm_dma_map_host(&queue->cq_mem, state->ctrlr, cq_buf, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(cq_buf);
		return err;
	}

	err = nvm_admin_cq_create(state->aq, &state->cq[qid], qid, queue->cq_mem, 0, queue->base.capacity, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O completion queue, err: %d", err);
		return err;
	}

	err = posix_memalign(&sq_buf, 4096, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}

	err = nvm_dma_map_host(&queue->sq_mem, state->ctrlr, sq_buf, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(sq_buf);
		return err;
	}

	err = nvm_admin_sq_create(state->aq, &state->sq[qid], &state->cq[qid], qid, queue->sq_mem, 0, queue->base.capacity, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O submission queue, err: %d", err);
		return err;
	}

	queue->cq = &state->cq[qid];
	queue->sq = &state->sq[qid];

	return 0;
}

int
xnvme_be_bam_queue_term(struct xnvme_queue *q)
{
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)q;
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)queue->base.dev->be.state;
	int err;

	err = nvm_admin_sq_delete(state->aq, queue->sq, queue->cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O submission queue, err: %d", err);
		return err;
	}

	err = nvm_admin_cq_delete(state->aq, queue->cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O completion queue, err: %d", err);
		return err;
	}

	nvm_dma_unmap(queue->cq_mem);
	nvm_dma_unmap(queue->sq_mem);
	return 0;
}

int
xnvme_be_bam_queue_poke(struct xnvme_queue *queue, uint32_t max)
{
	struct xnvme_queue_bam *q = (struct xnvme_queue_bam *)queue;
	struct xnvme_cmd_ctx *ctx;
	struct xnvme_spec_cpl *cpl;

	unsigned int reaped = 0;

	if (!max) {
		max = queue->base.outstanding;
	}

	do {
		cpl = (struct xnvme_spec_cpl *)nvm_cq_dequeue(q->cq);
		if (!cpl) {
			break;
		}
		nvm_sq_update(q->sq);

		reaped++;

		ctx = (struct xnvme_cmd_ctx *)&queue->pool_storage[cpl->cid];
		memcpy(&ctx->cpl, cpl, sizeof(ctx->cpl));
		ctx->async.cb(ctx, ctx->async.cb_arg);

	} while (reaped < max);

	queue->base.outstanding -= reaped;

	if (reaped) {
		nvm_cq_update(q->cq);
	}

	return reaped;
}

int
xnvme_be_bam_async_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *mbuf,
			   size_t mbuf_nbytes)
{
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)ctx->async.queue;
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)queue->base.dev->be.state;
	uint32_t cmd_id = ((struct xnvme_cmd_ctx_entry *)ctx)->id;
	struct xnvme_be_bam_memory *m;
	nvm_cmd_t *cmd;
	nvm_prp_list_t list;

	ctx->cmd.common.cid = cmd_id;
	cmd = nvm_sq_enqueue(queue->sq);
	memcpy(cmd, &ctx->cmd, sizeof(nvm_cmd_t));


	if (dbuf) {
		m = xnvme_be_bam_memory_find(state, dbuf);
		if (!m) {
			XNVME_DEBUG("FAILED: couldn't find memory in skiplist");
			return -ENOENT;
		}

		uint64_t offset = ((uint64_t)dbuf - (uint64_t)m->mem->vaddr)/m->mem->page_size;
		uint64_t remainder = (((uint64_t)dbuf - (uint64_t)m->mem->vaddr)%m->mem->page_size);
		uint64_t addr = m->mem->ioaddrs[offset] + remainder;

		list = NVM_PRP_LIST(queue->sq_mem, NVM_SQ_PAGES(queue->sq_mem, queue->sq->qs));
		nvm_cmd_data(cmd, 1, &list, ctx->dev->geo.mdts_nbytes, &addr);
	}

	nvm_sq_submit(queue->sq);
	queue->base.outstanding++;

	return 0;
}

#endif

struct xnvme_be_async g_xnvme_be_bam_async = {
#ifdef XNVME_BE_BAM_ENABLED
	.cmd_io = xnvme_be_bam_async_cmd_io,
	.cmd_iov = xnvme_be_nosys_queue_cmd_iov,
	.poke = xnvme_be_bam_queue_poke,
	.wait = xnvme_be_nosys_queue_wait,
	.init = xnvme_be_bam_queue_init,
	.term = xnvme_be_bam_queue_term,
	.get_completion_fd = xnvme_be_nosys_queue_get_completion_fd,
#else
	.cmd_io = xnvme_be_nosys_queue_cmd_io,
	.cmd_iov = xnvme_be_nosys_queue_cmd_iov,
	.poke = xnvme_be_nosys_queue_poke,
	.wait = xnvme_be_nosys_queue_wait,
	.init = xnvme_be_nosys_queue_init,
	.term = xnvme_be_nosys_queue_term,
	.get_completion_fd = xnvme_be_nosys_queue_get_completion_fd,
#endif
	.id = "bam",
};
