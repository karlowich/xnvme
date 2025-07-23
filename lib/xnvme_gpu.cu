#include "libxnvme.h"
#include <xnvme_cmd.h>
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

#define XNVME_GPU_MAX_NBYTES 4096

__global__ void
_cmd_submit(struct xnvme_dev *dev, uint32_t opc, uint64_t slba, uint64_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf, uint32_t n_threads)
{
	uint64_t i = 0;
	while(true) {
		struct xnvme_cmd_ctx ctx = {.dev = dev, .opts = XNVME_CMD_SYNC};
		uint64_t tid = blockIdx.x * blockDim.x + threadIdx.x + i*n_threads;
		uint64_t cur_slba = slba + tid * (nlb + 1);

		if (cur_slba + nlb > elba) { // continue until reaching elba
			return;
		}
		ctx.cmd.common.nsid = dev->ident.nsid;
		ctx.cmd.common.opcode = opc;
		ctx.cmd.nvm.nlb = nlb;
		ctx.cmd.nvm.slba = cur_slba;

		void *buf = (char *) dbuf + (cur_slba - slba) * dev->geo.lba_nbytes;

		xnvme_be_bam_gpu_cmd_io(&ctx, buf, nbytes, NULL, 0);
		i++;
	}
}

int
xnvme_gpu_cmd_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint64_t slba, uint64_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf)
{
	cudaError_t err;
	if(nbytes > XNVME_GPU_MAX_NBYTES) {
		XNVME_DEBUG("IO sizes beyond 4096 are unsupported");
		return -EINVAL;
	}
	_cmd_submit<<<grid_size, tblock_size>>>(dev, opc, slba, elba, nlb, nbytes, dbuf, grid_size * tblock_size);
	err = cudaGetLastError();
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error launching kernel: %s", cudaGetErrorString(err));
		return err;
	}
	err = cudaDeviceSynchronize();
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error synchronizing: %s", cudaGetErrorString(err));
		return err;
	}

	return 0;
}

__global__ void
_range_submit(struct xnvme_dev *dev, uint32_t opc, uint64_t *slbas, uint32_t nlb, uint64_t nbytes, void **dbufs, uint32_t *offsets, uint32_t n_io, uint32_t n_threads)
{
	void *buf;
	uint64_t tid;
	uint64_t i = 0;
	while(true) {
		struct xnvme_cmd_ctx ctx = {.dev = dev, .opts = XNVME_CMD_SYNC};
		tid = blockIdx.x * blockDim.x + threadIdx.x + i*n_threads;

		if (tid >= n_io) {
			return;
		}

		ctx.cmd.common.nsid = dev->ident.nsid;
		ctx.cmd.common.opcode = opc;
		ctx.cmd.nvm.nlb = nlb;
		ctx.cmd.nvm.slba = slbas[tid];

		buf = (char *) dbufs[tid] + offsets[tid] * dev->geo.lba_nbytes;

		xnvme_be_bam_gpu_cmd_io(&ctx, buf, nbytes, NULL, 0);
		i++;
	}
}

int
xnvme_gpu_range_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint64_t *slbas, uint64_t *elbas, uint32_t nlb, uint64_t nbytes, void **dbufs, uint32_t n_ranges)
{
	struct xnvme_gpu_io *io;
	uint32_t n_io = 0;
	uint32_t range = 0;
	uint32_t offset = 0;
	cudaError_t cerr;
	int err = 0;

	if(nbytes > XNVME_GPU_MAX_NBYTES) {
		XNVME_DEBUG("IO sizes beyond 4096 are unsupported");
		return -EINVAL;
	}

	for (uint32_t i = 0; i < n_ranges; i++) {
		n_io += ((elbas[i] - slbas[i]) + 1) / (nlb + 1);
	}

	err = xnvme_gpu_io_alloc(&io, n_io);	
	if (err) {
		XNVME_DEBUG("Error allocating struct xnvme_gpu_io: %d", err);
		return err;
	}

	for (uint32_t i = 0; i < n_io; i++) {
		io->slbas[i] = slbas[range] + offset;
		io->offsets[i] = offset;
		io->buffers[i] = dbufs[range];
		offset += nlb + 1;
		if (slbas[range] + offset > elbas[range]) {
			range++;
			offset = 0;
		}
	}

	_range_submit<<<grid_size, tblock_size>>>(dev, opc, io->slbas, nlb, nbytes, io->buffers, io->offsets, n_io, grid_size * tblock_size);
	cerr = cudaGetLastError();
	if (cerr != cudaSuccess) {
		XNVME_DEBUG("Error launching kernel: %s", cudaGetErrorString(cerr));
		err = cerr;
		goto exit;
	}

	err = xnvme_gpu_sync();
	if (err) {
		XNVME_DEBUG("xnvme_gpu_sync: %d", err);
		goto exit;
	}

exit:
	xnvme_gpu_io_free(io);

	return err;
}


int
xnvme_gpu_io_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint32_t nlb, uint64_t nbytes, struct xnvme_gpu_io *io)
{
	cudaError_t err;

	if(nbytes > XNVME_GPU_MAX_NBYTES) {
		XNVME_DEBUG("IO sizes beyond 4096 are unsupported");
		return -EINVAL;
	}

	_range_submit<<<grid_size, tblock_size>>>(dev, opc, io->slbas, nlb, nbytes, io->buffers, io->offsets, io->n_io, grid_size * tblock_size);

	err = cudaGetLastError();
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error launching kernel: %s", cudaGetErrorString(err));
	}
	return err;
}

void *
xnvme_gpu_alloc(const struct xnvme_dev *dev, size_t nbytes)
{
	return xnvme_be_bam_gpu_buf_alloc(dev, nbytes, 0);
}

void
xnvme_gpu_free(const struct xnvme_dev *dev, void *buf)
{
	xnvme_be_bam_gpu_buf_free(dev, buf);
}

int
xnvme_gpu_create_queues(struct xnvme_dev *dev, uint16_t capacity, uint16_t nqueues)
{
	return xnvme_be_bam_gpu_create_queues(dev, capacity, nqueues);
}


int
xnvme_gpu_delete_queues(struct xnvme_dev *dev)
{
	return xnvme_be_bam_gpu_delete_queues(dev);
}

int
xnvme_gpu_io_alloc(struct xnvme_gpu_io **io, uint64_t max_io) {
	struct xnvme_gpu_io *_io;
	cudaError_t cerr;
	int err;

	_io = (struct xnvme_gpu_io *) malloc(sizeof(struct xnvme_gpu_io));
	if (!_io) {
		err = errno;
		XNVME_DEBUG("Error allocating memory: %d", err);
		return err;
	}

	cerr = cudaMallocManaged(&_io->slbas, max_io * sizeof(uint64_t));
	if (cerr != cudaSuccess) {
		XNVME_DEBUG("Error allocating memory: %s", cudaGetErrorString(cerr));
		return cerr;
	}

	cerr = cudaMallocManaged(&_io->offsets, max_io * sizeof(uint32_t));
	if (cerr != cudaSuccess) {
		XNVME_DEBUG("Error allocating memory: %s", cudaGetErrorString(cerr));
		cudaFree(_io->slbas);
		return cerr;
	}

	cerr = cudaMallocManaged(&_io->buffers, max_io * sizeof(void *));
	if (cerr != cudaSuccess) {
		XNVME_DEBUG("Error allocating memory: %s", cudaGetErrorString(cerr));
		cudaFree(_io->slbas);
		cudaFree(_io->offsets);
		return cerr;
	}
	_io->max_io = max_io;

	*io = _io;
	return 0;
}

void
xnvme_gpu_io_free(struct xnvme_gpu_io *io) {
	cudaFree(io->buffers);
	cudaFree(io->offsets);
	cudaFree(io->slbas);
	free(io);
}

int
xnvme_gpu_sync() {
	cudaError_t err;
	err = cudaDeviceSynchronize();
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error synchronizing: %s", cudaGetErrorString(err));
		return err;
	}
	return 0;
}
