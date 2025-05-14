// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause
#include <errno.h>
#include <libxnvme.h>

struct range {
	uint64_t slba;
	uint64_t elba;
	uint32_t nio;
	void *dbuf;
};

struct work {
	uint32_t opc;
	uint32_t nlb;
	uint64_t nbytes;

	uint32_t n_ranges;
	uint32_t cur_range;

	struct range *ranges;
	uint32_t errors;
};

int
_submit(struct work *work, struct xnvme_cmd_ctx *ctx)
{
	int err;
	ctx->cmd.common.opcode = work->opc;
	ctx->cmd.common.nsid = xnvme_dev_get_nsid(ctx->dev);
	if (work->ranges[work->cur_range].slba >= work->ranges[work->cur_range].elba) {
		work->cur_range += 1;
	}
	if (work->cur_range >= work->n_ranges) {
		xnvme_queue_put_cmd_ctx(ctx->async.queue, ctx);
		return 0;
	}

	ctx->cmd.nvm.slba = work->ranges[work->cur_range].slba;
	ctx->cmd.nvm.nlb = work->nlb;

submit:
	err = xnvme_cmd_pass(ctx, work->ranges[work->cur_range].dbuf,
			     work->nbytes, NULL, 0);
	switch (err) {
	case 0:
		work->ranges[work->cur_range].slba += (work->nlb + 1);
		work->ranges[work->cur_range].dbuf += work->nbytes;
		break;

	// Submission failed: queue is full => process completions and try again
	case -EBUSY:
	case -EAGAIN:
		xnvme_queue_poke(ctx->async.queue, 0);
		goto submit;

	// Submission failed: unexpected error, put the command-context back in the
	// queue
	default:
		XNVME_DEBUG("Failed to submit, err: %d", err);
		xnvme_queue_put_cmd_ctx(ctx->async.queue, ctx);
		return err;
	}
	return 0;
}

static void
cb_fn(struct xnvme_cmd_ctx *ctx, void *cb_arg)
{
	struct work *work = cb_arg;
	if (xnvme_cmd_ctx_cpl_status(ctx)) {
		xnvme_cmd_ctx_pr(ctx, XNVME_PR_DEF);
		((struct work *)cb_arg)->errors++;
		xnvme_queue_put_cmd_ctx(ctx->async.queue, ctx);
	}

	if (work->cur_range >= work->n_ranges) {
		xnvme_queue_put_cmd_ctx(ctx->async.queue, ctx);
		return;
	}
	_submit(work, ctx);
}

int
xnvme_io_range_submit(struct xnvme_queue *queue, uint32_t opc, uint64_t *slbas, uint64_t *elbas,
		      uint32_t nlb, uint64_t nbytes, void **dbufs, uint32_t n_ranges)
{
	int err;
	uint32_t n_blocks;
	struct range *range;
	struct work work = {0};
	work.nlb = nlb;
	work.n_ranges = n_ranges;
	work.nbytes = nbytes;
	work.opc = opc;
	struct range ranges[n_ranges];
	work.ranges = ranges;
	int capacity = xnvme_queue_get_capacity(queue);

	err = xnvme_queue_set_cb(queue, cb_fn, &work);
	if (err) {
		XNVME_DEBUG("Failed to set queue callback, err: %d", err);
		return err;
	}

	for (uint32_t i = 0; i < n_ranges; i++) {
		range = &work.ranges[i];
		range->slba = slbas[i];
		range->elba = elbas[i];
		range->dbuf = dbufs[i];
		n_blocks = (range->elba - range->slba) + 1;
		if (n_blocks % (nlb + 1) != 0) {
			XNVME_DEBUG("n_blocks (%d) is not divisible by nlb + 1 (%d)", n_blocks,
				    nlb + 1)
			return -EINVAL;
		}

		range->nio = n_blocks / (nlb + 1);
	}

	for (int i = 0; i < capacity - 1; i++) {
		struct xnvme_cmd_ctx *ctx = xnvme_queue_get_cmd_ctx(queue);
		err = _submit(&work, ctx);
		if (err) {
			break;
		}
	}
	xnvme_queue_drain(queue);
	if (work.errors) {
		return -EIO;
	}
	return err;
}
