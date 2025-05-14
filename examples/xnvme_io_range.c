
// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

#include <errno.h>
#include <libxnvme.h>

#define DEFAULT_QD 32

static int
sub_async_read(struct xnvme_cli *cli)
{
	struct xnvme_dev *dev = cli->args.dev;
	const struct xnvme_geo *geo = xnvme_dev_get_geo(dev);
	struct xnvme_lba_range rng = {0};
	uint32_t qd, nlb, nbytes;

	struct xnvme_queue *queue = NULL;

	void *buf = NULL;
	int err;

	if (geo->type != XNVME_GEO_CONVENTIONAL) {
		XNVME_DEBUG("FAILED: not nvm, got; %d", geo->type);
		return EINVAL;
	}

	qd = cli->given[XNVME_CLI_OPT_QDEPTH] ? cli->args.qdepth : DEFAULT_QD;
	nlb = 7;
	nbytes = (nlb + 1) * geo->lba_nbytes;

	rng = xnvme_lba_range_from_slba_elba(dev, cli->args.slba, cli->args.elba);
	if (!rng.attr.is_valid) {
		err = -EINVAL;
		xnvme_cli_perr("invalid range", err);
		xnvme_lba_range_pr(&rng, XNVME_PR_DEF);
		return err;
	}

	xnvme_cli_pinf("Allocating and filling buf of nbytes: %zu", rng.nbytes);
	buf = xnvme_buf_alloc(dev, rng.nbytes);
	if (!buf) {
		err = -errno;
		xnvme_cli_perr("xnvme_buf_alloc()", err);
		goto exit;
	}
	err = xnvme_buf_fill(buf, rng.nbytes, "zero");
	if (err) {
		xnvme_cli_perr("xnvme_buf_fill()", err);
		goto exit;
	}

	xnvme_cli_pinf("Initializing queue and setting default callback function and arguments");
	err = xnvme_queue_init(dev, qd, 0, &queue);
	if (err) {
		xnvme_cli_perr("xnvme_queue_init()", err);
		goto exit;
	}

	xnvme_cli_pinf("Read uri: '%s', qd: %d", cli->args.uri, qd);
	xnvme_lba_range_pr(&rng, XNVME_PR_DEF);

	xnvme_cli_timer_start(cli);

	err = xnvme_io_range_submit(queue, XNVME_SPEC_NVM_OPC_READ, &rng.slba,
				    &rng.elba, nlb, nbytes, &buf, 1);
	if (err) {
		xnvme_cli_perr("xnvme_io_range_submit()", err);
	}

	xnvme_cli_timer_stop(cli);

	xnvme_cli_timer_bw_pr(cli, "wall-clock", rng.naddrs * geo->nbytes);

exit:
	if (queue) {
		int err_exit = xnvme_queue_term(queue);
		if (err_exit) {
			xnvme_cli_perr("xnvme_queue_term()", err_exit);
		}
	}
	xnvme_buf_free(dev, buf);

	return err < 0 ? err : 0;
}

//
// Command-Line Interface (CLI) definition
//

static struct xnvme_cli_sub g_subs[] = {
	{
		"read",
		"Read the LBAs [SLBA,ELBA]",
		"Read the LBAs [SLBA,ELBA]",
		sub_async_read,
		{
			{XNVME_CLI_OPT_POSA_TITLE, XNVME_CLI_SKIP},
			{XNVME_CLI_OPT_URI, XNVME_CLI_POSA},

			{XNVME_CLI_OPT_NON_POSA_TITLE, XNVME_CLI_SKIP},
			{XNVME_CLI_OPT_QDEPTH, XNVME_CLI_LOPT},
			{XNVME_CLI_OPT_SLBA, XNVME_CLI_LOPT},
			{XNVME_CLI_OPT_ELBA, XNVME_CLI_LOPT},

			XNVME_CLI_ASYNC_OPTS,
		},
	},
};

static struct xnvme_cli g_cli = {
	.title = "xNVMe: Range IO Example",
	.descr_short = "xNVMe: Range IO Example: read",
	.subs = g_subs,
	.nsubs = sizeof g_subs / sizeof(*g_subs),
};

int
main(int argc, char **argv)
{
	return xnvme_cli_run(&g_cli, argc, argv, XNVME_CLI_INIT_DEV_OPEN);
}
