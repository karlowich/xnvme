// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <libxnvme.h>
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <fcntl.h>
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

int
xnvme_be_bam_dev_open(struct xnvme_dev *dev)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	const struct xnvme_ident *ident = &dev->ident;
	nvm_dma_t *aq_mem;
	void *buf;
	int fd, err;

	fd = open(ident->uri, O_RDWR);

	if (fd < 0) {
		XNVME_DEBUG("FAILED: open(uri: '%s'), fd: %d, errno: %d", ident->uri, fd, errno);
		return -errno;
	}

	err = nvm_ctrl_init(&state->ctrlr, fd);
	close(fd);
	if (err) {
		XNVME_DEBUG("FAILED: could not initialize controller from fd: %d, err: %d", fd, err);
		return err;
	}

	state->list = (struct skiplist *) malloc(sizeof(struct skiplist));
	if (!state->list) {
		XNVME_DEBUG("FAILED: could not allocate memory for skiplist");
		return -ENOMEM;
	}
	skiplist_init(state->list);

	err = posix_memalign(&buf, 4096, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}

	err = nvm_dma_map_host(&aq_mem, state->ctrlr, buf, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(buf);
		return err;
	}

	err = nvm_aq_create(&state->aq, state->ctrlr, aq_mem);
	nvm_dma_unmap(aq_mem);
	if (err) {
		XNVME_DEBUG("FAILED: could not create admin queues, err: %d", err);
		return err;
	}

	dev->ident.dtype = XNVME_DEV_TYPE_NVME_NAMESPACE;
	dev->ident.nsid = dev->opts.nsid;
	dev->ident.csi = XNVME_SPEC_CSI_NVM;

	return 0;
}

void
xnvme_be_bam_dev_close(struct xnvme_dev *dev)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;

	nvm_aq_destroy(state->aq);
	nvm_ctrl_free(state->ctrlr);
}

#endif

struct xnvme_be_dev g_xnvme_be_bam_dev = {
#ifdef XNVME_BE_BAM_ENABLED
	.enumerate = xnvme_be_nosys_enumerate,
	.dev_open = xnvme_be_bam_dev_open,
	.dev_close = xnvme_be_bam_dev_close,
#else
	.enumerate = xnvme_be_nosys_enumerate,
	.dev_open = xnvme_be_nosys_dev_open,
	.dev_close = xnvme_be_nosys_dev_close,
#endif
};
