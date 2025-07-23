/**
 * SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * @headerfile libxnvme_gpu.h
 */

struct xnvme_gpu_io {
	void **buffers;
	uint64_t *slbas;
	uint32_t *offsets;
	uint64_t max_io;
	uint64_t n_io;
};

int
xnvme_gpu_cmd_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc,
		     uint64_t slba, uint64_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf);
int
xnvme_gpu_range_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev,
		       uint32_t opc, uint64_t *slbas, uint64_t *elbas, uint32_t nlb,
		       uint64_t nbytes, void **dbufs, uint32_t n_ranges);

void *
xnvme_gpu_alloc(const struct xnvme_dev *dev, size_t nbytes);

void
xnvme_gpu_free(const struct xnvme_dev *dev, void *buf);

int
xnvme_gpu_create_queues(struct xnvme_dev *dev, uint16_t capacity, uint16_t nqueues);

int
xnvme_gpu_delete_queues(struct xnvme_dev *dev);

int
xnvme_gpu_io_alloc(struct xnvme_gpu_io **io, uint64_t max_io);

void
xnvme_gpu_io_free(struct xnvme_gpu_io *io);

int
xnvme_gpu_io_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc,
		    uint32_t nlb, uint64_t nbytes, struct xnvme_gpu_io *io);

int
xnvme_gpu_sync(void);
