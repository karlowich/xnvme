#include <xnvme_cmd.h>
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

__global__ void
_cmd_submit(struct xnvme_dev *dev, uint32_t opc, uint32_t slba, uint32_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf, uint32_t n_threads)
{
	uint64_t i = 0;
	while(true) {
		struct xnvme_cmd_ctx ctx = {.dev = dev, .opts = XNVME_CMD_SYNC};
		uint64_t tid = blockIdx.x * blockDim.x + threadIdx.x + i*n_threads;
		uint32_t cur_slba = slba + tid * (nlb + 1);

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
xnvme_kernels_cmd_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint32_t slba, uint32_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf)
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
_range_submit(struct xnvme_dev *dev, uint32_t opc, uint32_t *slbas, uint32_t *elbas, uint32_t nlb, uint64_t nbytes, void **dbufs, uint32_t n_ranges, uint32_t n_threads)
{
	void *dbuf, *buf;
	uint32_t range, slba, elba, cur_slba;
	uint64_t tid;
	uint64_t i = 0;
	while(true) {
		struct xnvme_cmd_ctx ctx = {.dev = dev, .opts = XNVME_CMD_SYNC};
		tid = blockIdx.x * blockDim.x + threadIdx.x + i*n_threads;

		range = 0;
		do {
			if (range >= n_ranges) { // keep going until every range is finished
				return;
			}
			slba = slbas[range];
			elba = elbas[range];
			dbuf = dbufs[range];

			cur_slba = slba + tid * (nlb + 1);
			tid -= (elba - slba) + 1;
			range++;
		} while (cur_slba + nlb > elba);

		ctx.cmd.common.nsid = dev->ident.nsid;
		ctx.cmd.common.opcode = opc;
		ctx.cmd.nvm.nlb = nlb;
		ctx.cmd.nvm.slba = cur_slba;

		buf = (char *) dbuf + (cur_slba - slba) * dev->geo.lba_nbytes;

		xnvme_be_bam_sync_cmd_io(&ctx, buf, nbytes, NULL, 0);
		i++;
	}
}

int
xnvme_kernels_range_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint32_t *slbas, uint32_t *elbas, uint32_t nlb, uint64_t nbytes, void **dbufs, uint32_t n_ranges)
{
	cudaError_t err;
	_range_submit<<<grid_size, tblock_size>>>(dev, opc, slbas, elbas, nlb, nbytes, dbufs, n_ranges, grid_size * tblock_size);
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
