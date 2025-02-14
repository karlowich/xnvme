// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <libxnvme.h>
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <errno.h>
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

int
xnvme_be_bam_sync_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *mbuf,
			  size_t mbuf_nbytes)
{
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
