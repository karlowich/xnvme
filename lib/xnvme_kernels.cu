#include <xnvme_cmd.h>
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

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

		xnvme_be_bam_sync_cmd_io(&ctx, buf, nbytes, NULL, 0);
		i++;
	}
}

int
xnvme_kernels_cmd_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint64_t slba, uint64_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf)
{
	cudaError_t err;
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

		xnvme_be_bam_sync_cmd_io(&ctx, buf, nbytes, NULL, 0);
		i++;
	}
}

int
xnvme_kernels_range_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint64_t *slbas, uint64_t *elbas, uint32_t nlb, uint64_t nbytes, void **dbufs, uint32_t n_ranges)
{
	cudaError_t err;
	uint64_t *gpu_slbas;
	uint32_t *offsets;
	void **buffers;
	uint32_t n_io = 0;
	uint32_t range = 0;
	uint32_t offset = 0;

	for (uint32_t i = 0; i < n_ranges; i++) {
		n_io += ((elbas[i] - slbas[i]) + 1) / (nlb + 1);
	}

	err = cudaMallocManaged(&gpu_slbas, n_io * sizeof(uint64_t));
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error allocating memory: %s", cudaGetErrorString(err));
	}

	err = cudaMallocManaged(&offsets, n_io * sizeof(uint32_t));
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error allocating memory: %s", cudaGetErrorString(err));
	}

	err = cudaMallocManaged(&buffers, n_io * sizeof(void *));
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error allocating memory: %s", cudaGetErrorString(err));
	}

	for (uint32_t i = 0; i < n_io; i++) {
		gpu_slbas[i] = slbas[range] + offset;
		offsets[i] = offset;
		buffers[i] = dbufs[range];
		offset += nlb + 1;
		if (slbas[range] + offset > elbas[range]) {
			range++;
			offset = 0;
		}
	}

	_range_submit<<<grid_size, tblock_size>>>(dev, opc, gpu_slbas, nlb, nbytes, buffers, offsets, n_io, grid_size * tblock_size);
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
