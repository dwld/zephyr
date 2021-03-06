/*
 * Copyright (c) 2018 Nordic Semiconductor ASA
 * Copyright (c) 2015 Runtime Inc
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdlib.h>
#include <string.h>

#include "settings_test.h"
#include "settings_priv.h"

void config_setup_nffs(void);

void test_main(void)
{
	ztest_test_suite(test_config_fcb,
			 /* Config tests */
			 ztest_unit_test(config_empty_lookups),
			 ztest_unit_test(test_config_insert),
			 ztest_unit_test(test_config_getset_unknown),
			 ztest_unit_test(test_config_getset_int),
			 ztest_unit_test(test_config_getset_int64),
			 ztest_unit_test(test_config_commit),
			 /* NFFS as backing storage. */
			 ztest_unit_test(config_setup_nffs),
			 ztest_unit_test(test_config_empty_file),
			 ztest_unit_test(test_config_small_file),
			 ztest_unit_test(test_config_multiple_in_file),
			 ztest_unit_test(test_config_save_in_file),
			 ztest_unit_test(test_config_save_one_file),
			 ztest_unit_test(test_config_compress_file)
			);

	ztest_run_test_suite(test_config_fcb);
}
