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
#include <sys/eventfd.h>

struct xnvme_queue_bam {
	struct xnvme_queue_base base;

	struct nvme_sq *sq;
	struct nvme_cq *cq;
	uint id;

	uint8_t _rsvd[208];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_queue_bam) == XNVME_BE_QUEUE_STATE_NBYTES,
		    "Incorrect size")

int
xnvme_be_bam_queue_init(struct xnvme_queue *q, int XNVME_UNUSED(opts))
{
	return 0;
}

int
xnvme_be_bam_queue_term(struct xnvme_queue *q)
{
	return 0;
}

int
xnvme_be_bam_queue_poke(struct xnvme_queue *queue, uint32_t max)
{
	return 0;
}

int
xnvme_be_bam_async_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *mbuf,
			   size_t mbuf_nbytes)
{

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
