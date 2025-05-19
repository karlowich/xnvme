// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

#include <errno.h>
#include <libxnvme.h>

#define NRANGES 4

/**
 * Argument setup for I/O work
 */
struct iowork {
	const struct xnvme_geo *geo;
	struct xnvme_dev *dev;
	uint32_t nsid;

	uint32_t n_ranges;
	uint64_t nbytes; ///< Number of bytes pr. range
	uint64_t naddr; ///< Number of bytes pr. range
	uint64_t nio; ///< Number of I/Os to complete (count-from-1)
	struct iowork_range *ranges; ///< Range to confine I/O inside of

	struct {
		size_t nlb;    ///< Number of LBAs per I/O (count-from-0)
		size_t nbytes; ///< Number of bytes pr. I/O
		size_t naddr;  ///< Number of addresses per I/O (count-from-1)
	} io;                  ///< Per I/O args

	uint64_t *slbas;   ///< First LBA of the range
	uint64_t *elbas;   ///< Last LBA of the range

	char **rbufs;
	char **wbufs;
};

int
iowork_pp(struct iowork *work)
{
	int wrtn = 0;

	wrtn += printf("iowork:");
	if (!work) {
		wrtn += printf(" ~\n");
		return wrtn;
	}

	printf("\n");
	printf("  io.nbytes: %zu\n", work->io.nbytes);
	printf("  io.naddr: %zu\n", work->io.naddr);
	printf("  nbytes: %" PRIu64 "\n", work->nbytes);
	printf("  naddr: %" PRIu64 "\n", work->naddr);
	printf("  nio: %" PRIu64 "\n", work->nio);
	for (uint32_t i = 0; i < work->n_ranges; i++) {
		printf("  slbas[%" PRIu32 "]: %" PRIu64 "\n", i, work->slbas[i]);
		printf("  elbas[%" PRIu32 "]: %" PRIu64 "\n", i, work->elbas[i]);
	}

	return 0;
}


/**
 * Tear down function for I/O worker arguments
 */
static int
iowork_teardown(struct iowork *work)
{
	for (uint32_t i = 0; i < work->n_ranges; i++) {
		xnvme_buf_free(work->dev, work->rbufs[i]);
		xnvme_buf_free(work->dev, work->wbufs[i]);
	}
	cudaFree(work->slbas);
	cudaFree(work->elbas);
	cudaFree(work->rbufs);
	cudaFree(work->wbufs);

	return 0;
}

static int
iowork_from_cli(struct xnvme_cli *cli, struct iowork *work)
{
	int err;

	cudaMemset(work, 0, sizeof(struct iowork));

	work->dev = cli->args.dev;
	work->nsid = xnvme_dev_get_nsid(work->dev);
	work->geo = xnvme_dev_get_geo(work->dev);

	work->io.nlb = cli->given[XNVME_CLI_OPT_NLB] ? cli->args.nlb : 0;
	work->io.naddr = work->io.nlb + 1;
	work->io.nbytes = work->io.naddr * work->geo->lba_nbytes;
	work->n_ranges = NRANGES;
	work->nbytes = 1 << 24;
	work->naddr = work->nbytes / work->geo->lba_nbytes;
	work->nio = work->n_ranges * work->naddr;

	cudaMallocManaged(&work->slbas, sizeof(uint64_t));
	cudaMallocManaged(&work->elbas, sizeof(uint64_t));
	cudaMallocManaged(&work->rbufs, sizeof(char *));
	cudaMallocManaged(&work->wbufs, sizeof(char *));

	for (uint32_t i = 0; i < work->n_ranges; i++) {
		work->slbas[i] = i * work->naddr;
		work->elbas[i] = work->slbas[i] + work->naddr - 1;
		work->wbufs[i] = (char *) xnvme_buf_alloc(cli->args.dev, work->nbytes);
		if (!work->wbufs[i]) {
			err = -errno;
			XNVME_DEBUG("FAILED: xnvme_buf_alloc(wbuf), err: %d", errno);
			goto failed;
		}
		xnvme_buf_fill(work->wbufs[i], work->nbytes, "rand-t");

		work->rbufs[i] = (char *) xnvme_buf_alloc(cli->args.dev, work->nbytes);
		if (!work->rbufs[i]) {
			err = -errno;
			XNVME_DEBUG("FAILED: xnvme_buf_alloc(rbuf), err: %d", errno);
			goto failed;
		}
		xnvme_buf_fill(work->rbufs[i], work->nbytes, "zero");

	}
	return 0;

failed:
	iowork_teardown(work);
	return err;
}

static int
final(struct iowork work)
{
	size_t diff;
	int err = 0;

	for (uint32_t i = 0; i < work.n_ranges; i++) {
		diff = xnvme_buf_diff(work.wbufs[i], work.rbufs[i], work.nbytes);
		if (diff) {
			xnvme_cli_pinf("ERR in range %" PRIu32 ": {diff: %" PRIu64 "}", i, diff);
			err = -EIO;
		}
	}
	iowork_teardown(&work);

	if (err){
		return err;
	}

	xnvme_cli_pinf("SUCCESS!");
	return 0;
}

static int
test_verify(struct xnvme_cli *cli)
{
	struct iowork *work;
	int err, x, y;

	cudaMallocManaged(&work, sizeof(struct iowork));
	err = iowork_from_cli(cli, work);
	if (err) {
		XNVME_DEBUG("FAILED: iowork_from_cli(), err: %d", err);
		return err;
	}

	iowork_pp(work);
	xnvme_dev_pr(work->dev, XNVME_PR_DEF);

	for (int i = 0; i < 2; i++) {

		void ** cur_bufs = i ? (void **)work->rbufs : (void **)work->wbufs;
		int opc = i ? XNVME_SPEC_NVM_OPC_READ : XNVME_SPEC_NVM_OPC_WRITE;


		y = 64;
		x = (work->nio + y - 1)/y;

		err = xnvme_gpu_range_submit(x, y, work->dev, opc, work->slbas, work->elbas, work->io.nlb, work->io.nbytes, cur_bufs, work->n_ranges);
		if (err) {
			return err;
		}
	}

	return final(*work);
}

static struct xnvme_cli_sub g_subs[] = {
	{
		"verify",
		"Write, then read and compare",
		"Write, then read and compare",
		test_verify,
		{
			{XNVME_CLI_OPT_POSA_TITLE, XNVME_CLI_SKIP},
			{XNVME_CLI_OPT_URI, XNVME_CLI_POSA},

			{XNVME_CLI_OPT_NON_POSA_TITLE, XNVME_CLI_SKIP},
			{XNVME_CLI_OPT_NLB, XNVME_CLI_LOPT},
			XNVME_CLI_SYNC_OPTS,
		},
	},
};

static struct xnvme_cli g_cli = {
	.title = "Test xNVMe basic buffer alloc/free",
	.descr_short = "Test xNVMe basic buffer alloc/free",
	.nsubs = sizeof g_subs / sizeof(*g_subs),
	.subs = g_subs,
};

int
main(int argc, char **argv)
{
	return xnvme_cli_run(&g_cli, argc, argv, XNVME_CLI_INIT_DEV_OPEN);
}
