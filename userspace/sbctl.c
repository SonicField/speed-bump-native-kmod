/*
 * sbctl - Speed Bump Control Tool
 *
 * Userspace utility for configuring the speed_bump kernel module via sysfs.
 *
 * SPDX-License-Identifier: GPL-2.0
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SYSFS_BASE "/sys/kernel/speed_bump"
#define SYSFS_TARGETS SYSFS_BASE "/targets"
#define SYSFS_TARGETS_LIST SYSFS_BASE "/targets_list"
#define SYSFS_ENABLED SYSFS_BASE "/enabled"
#define SYSFS_STATS SYSFS_BASE "/stats"
#define SYSFS_DEFAULT_DELAY SYSFS_BASE "/default_delay_ns"

#define MAX_PATH_LEN 256
#define MAX_SYMBOL_LEN 128
#define MAX_DELAY_NS 10000000000UL
#define READ_BUF_SIZE 4096

static const char *prog_name;

static void print_usage(void)
{
	fprintf(stderr,
		"Usage: %s <command> [options]\n"
		"\n"
		"Commands:\n"
		"  add PATH:SYMBOL [DELAY_NS]  Add a target with optional delay\n"
		"  remove PATH:SYMBOL          Remove a specific target\n"
		"  update PATH:SYMBOL DELAY_NS Update target's delay\n"
		"  list                        List all current targets\n"
		"  clear                       Remove all targets\n"
		"  enable                      Enable all probes\n"
		"  disable                     Disable all probes\n"
		"  status                      Show enabled state and statistics\n"
		"  delay [DELAY_NS]            Get or set default delay\n"
		"\n"
		"Options:\n"
		"  -h, --help                  Show this help message\n"
		"  -v, --version               Show version\n"
		"\n"
		"Examples:\n"
		"  %s add /usr/lib/libcuda.so:cudaLaunchKernel 10000\n"
		"  %s add /usr/bin/app:process_request\n"
		"  %s update /usr/bin/app:process_request 50000\n"
		"  %s remove /usr/lib/libcuda.so:cudaLaunchKernel\n"
		"  %s list\n"
		"  %s clear\n"
		"  %s enable\n"
		"  %s status\n"
		"  %s delay 1000000\n"
		"\n"
		"Target format:\n"
		"  PATH must be an absolute path to an ELF binary or shared library\n"
		"  SYMBOL must be a valid symbol name in the ELF symbol table\n"
		"  DELAY_NS is the delay in nanoseconds (0 to 10000000000)\n",
		prog_name, prog_name, prog_name, prog_name, prog_name,
		prog_name, prog_name, prog_name, prog_name, prog_name);
}

static void print_version(void)
{
	printf("sbctl version 1.0.0\n");
}

static int check_module_loaded(void)
{
	if (access(SYSFS_BASE, F_OK) != 0) {
		fprintf(stderr,
			"Error: speed_bump module not loaded\n"
			"Load it with: sudo modprobe speed_bump\n");
		return -1;
	}
	return 0;
}

static int write_sysfs(const char *path, const char *data)
{
	int fd;
	ssize_t len, written;

	fd = open(path, O_WRONLY);
	if (fd < 0) {
		if (errno == EACCES)
			fprintf(stderr, "Error: Permission denied (try with sudo)\n");
		else if (errno == ENOENT)
			fprintf(stderr, "Error: %s not found\n", path);
		else
			fprintf(stderr, "Error: Cannot open %s: %s\n",
				path, strerror(errno));
		return -1;
	}

	len = strlen(data);
	written = write(fd, data, len);
	if (written < 0) {
		int save_errno = errno;
		close(fd);
		switch (save_errno) {
		case EINVAL:
			fprintf(stderr, "Error: Invalid format\n");
			break;
		case ENOENT:
			fprintf(stderr, "Error: Path or symbol not found\n");
			break;
		case ENOEXEC:
			fprintf(stderr, "Error: Not a valid ELF file\n");
			break;
		case ENAMETOOLONG:
			fprintf(stderr, "Error: Path or symbol name too long\n");
			break;
		case ERANGE:
			fprintf(stderr, "Error: Delay value out of range\n");
			break;
		case EEXIST:
			fprintf(stderr, "Error: Target already exists\n");
			break;
		case ENOSPC:
			fprintf(stderr, "Error: Maximum target limit reached\n");
			break;
		case EBUSY:
			fprintf(stderr, "Error: Module is busy\n");
			break;
		case EACCES:
			fprintf(stderr, "Error: Permission denied\n");
			break;
		default:
			fprintf(stderr, "Error: Write failed: %s\n",
				strerror(save_errno));
		}
		return -1;
	}

	if (written != len) {
		close(fd);
		fprintf(stderr, "Error: Partial write (%zd of %zd bytes)\n",
			written, len);
		return -1;
	}

	close(fd);
	return 0;
}

static int read_sysfs(const char *path)
{
	int fd;
	char buf[READ_BUF_SIZE];
	ssize_t bytes_read;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		if (errno == EACCES)
			fprintf(stderr, "Error: Permission denied\n");
		else if (errno == ENOENT)
			fprintf(stderr, "Error: %s not found\n", path);
		else
			fprintf(stderr, "Error: Cannot open %s: %s\n",
				path, strerror(errno));
		return -1;
	}

	while ((bytes_read = read(fd, buf, sizeof(buf) - 1)) > 0) {
		buf[bytes_read] = '\0';
		printf("%s", buf);
	}

	if (bytes_read < 0) {
		close(fd);
		fprintf(stderr, "Error: Read failed: %s\n", strerror(errno));
		return -1;
	}

	close(fd);
	return 0;
}

static int validate_target(const char *target)
{
	const char *colon;
	size_t path_len, symbol_len;

	colon = strchr(target, ':');
	if (!colon) {
		fprintf(stderr, "Error: Invalid target format (missing ':')\n"
				"Expected: PATH:SYMBOL\n");
		return -1;
	}

	path_len = colon - target;
	symbol_len = strlen(colon + 1);

	if (path_len == 0) {
		fprintf(stderr, "Error: PATH cannot be empty\n");
		return -1;
	}

	if (target[0] != '/') {
		fprintf(stderr, "Error: PATH must be absolute (start with '/')\n");
		return -1;
	}

	if (path_len > MAX_PATH_LEN) {
		fprintf(stderr, "Error: PATH too long (max %d bytes)\n",
			MAX_PATH_LEN);
		return -1;
	}

	if (symbol_len == 0) {
		fprintf(stderr, "Error: SYMBOL cannot be empty\n");
		return -1;
	}

	if (symbol_len > MAX_SYMBOL_LEN) {
		fprintf(stderr, "Error: SYMBOL too long (max %d bytes)\n",
			MAX_SYMBOL_LEN);
		return -1;
	}

	return 0;
}

static int validate_delay(const char *delay_str, unsigned long *delay_out)
{
	char *endptr;
	unsigned long delay;

	errno = 0;
	delay = strtoul(delay_str, &endptr, 10);
	if (errno != 0 || *endptr != '\0' || endptr == delay_str) {
		fprintf(stderr, "Error: Invalid delay value '%s'\n", delay_str);
		return -1;
	}

	if (delay > MAX_DELAY_NS) {
		fprintf(stderr, "Error: Delay exceeds maximum (%lu ns)\n",
			MAX_DELAY_NS);
		return -1;
	}

	if (delay_out)
		*delay_out = delay;
	return 0;
}

static int cmd_add(int argc, char **argv)
{
	char cmd[512];
	int ret;
	unsigned long delay;

	if (argc < 1) {
		fprintf(stderr, "Error: 'add' requires PATH:SYMBOL argument\n");
		return 1;
	}

	if (validate_target(argv[0]) < 0)
		return 1;

	if (argc >= 2) {
		if (validate_delay(argv[1], &delay) < 0)
			return 1;
		ret = snprintf(cmd, sizeof(cmd), "+%s %lu", argv[0], delay);
	} else {
		ret = snprintf(cmd, sizeof(cmd), "+%s", argv[0]);
	}

	if (ret < 0 || (size_t)ret >= sizeof(cmd)) {
		fprintf(stderr, "Error: Command too long\n");
		return 1;
	}

	if (check_module_loaded() < 0)
		return 1;

	if (write_sysfs(SYSFS_TARGETS, cmd) < 0)
		return 1;

	printf("Added target: %s\n", argv[0]);
	return 0;
}

static int cmd_remove(int argc, char **argv)
{
	char cmd[512];
	int ret;

	if (argc < 1) {
		fprintf(stderr, "Error: 'remove' requires PATH:SYMBOL argument\n");
		return 1;
	}

	if (validate_target(argv[0]) < 0)
		return 1;

	ret = snprintf(cmd, sizeof(cmd), "-%s", argv[0]);
	if (ret < 0 || (size_t)ret >= sizeof(cmd)) {
		fprintf(stderr, "Error: Command too long\n");
		return 1;
	}

	if (check_module_loaded() < 0)
		return 1;

	if (write_sysfs(SYSFS_TARGETS, cmd) < 0)
		return 1;

	printf("Removed target: %s\n", argv[0]);
	return 0;
}

static int cmd_update(int argc, char **argv)
{
	char cmd[512];
	unsigned long delay;
	int ret;

	if (argc < 2) {
		fprintf(stderr, "Error: 'update' requires PATH:SYMBOL and DELAY_NS\n");
		return 1;
	}

	if (validate_target(argv[0]) < 0)
		return 1;

	if (validate_delay(argv[1], &delay) < 0)
		return 1;

	ret = snprintf(cmd, sizeof(cmd), "=%s %lu", argv[0], delay);
	if (ret < 0 || (size_t)ret >= sizeof(cmd)) {
		fprintf(stderr, "Error: Command too long\n");
		return 1;
	}

	if (check_module_loaded() < 0)
		return 1;

	if (write_sysfs(SYSFS_TARGETS, cmd) < 0)
		return 1;

	printf("Updated target: %s delay=%lu ns\n", argv[0], delay);
	return 0;
}

static int cmd_list(void)
{
	if (check_module_loaded() < 0)
		return 1;

	return read_sysfs(SYSFS_TARGETS_LIST) < 0 ? 1 : 0;
}

static int cmd_clear(void)
{
	if (check_module_loaded() < 0)
		return 1;

	if (write_sysfs(SYSFS_TARGETS, "-*") < 0)
		return 1;

	printf("All targets cleared\n");
	return 0;
}

static int cmd_enable(void)
{
	if (check_module_loaded() < 0)
		return 1;

	if (write_sysfs(SYSFS_ENABLED, "1") < 0)
		return 1;

	printf("Probes enabled\n");
	return 0;
}

static int cmd_disable(void)
{
	if (check_module_loaded() < 0)
		return 1;

	if (write_sysfs(SYSFS_ENABLED, "0") < 0)
		return 1;

	printf("Probes disabled\n");
	return 0;
}

static int cmd_status(void)
{
	if (check_module_loaded() < 0)
		return 1;

	return read_sysfs(SYSFS_STATS) < 0 ? 1 : 0;
}

static int cmd_delay(int argc, char **argv)
{
	unsigned long delay;
	char buf[32];

	if (check_module_loaded() < 0)
		return 1;

	if (argc == 0) {
		/* Get current default delay */
		return read_sysfs(SYSFS_DEFAULT_DELAY) < 0 ? 1 : 0;
	}

	/* Set new default delay */
	if (validate_delay(argv[0], &delay) < 0)
		return 1;

	snprintf(buf, sizeof(buf), "%lu", delay);
	if (write_sysfs(SYSFS_DEFAULT_DELAY, buf) < 0)
		return 1;

	printf("Default delay set to %lu ns\n", delay);
	return 0;
}

int main(int argc, char **argv)
{
	int opt;
	static struct option long_opts[] = {
		{"help", no_argument, NULL, 'h'},
		{"version", no_argument, NULL, 'v'},
		{NULL, 0, NULL, 0}
	};

	prog_name = argv[0];

	while ((opt = getopt_long(argc, argv, "hv", long_opts, NULL)) != -1) {
		switch (opt) {
		case 'h':
			print_usage();
			return 0;
		case 'v':
			print_version();
			return 0;
		default:
			print_usage();
			return 1;
		}
	}

	if (optind >= argc) {
		fprintf(stderr, "Error: No command specified\n\n");
		print_usage();
		return 1;
	}

	argc -= optind;
	argv += optind;

	if (strcmp(argv[0], "add") == 0)
		return cmd_add(argc - 1, argv + 1);
	else if (strcmp(argv[0], "remove") == 0)
		return cmd_remove(argc - 1, argv + 1);
	else if (strcmp(argv[0], "update") == 0)
		return cmd_update(argc - 1, argv + 1);
	else if (strcmp(argv[0], "list") == 0)
		return cmd_list();
	else if (strcmp(argv[0], "clear") == 0)
		return cmd_clear();
	else if (strcmp(argv[0], "enable") == 0)
		return cmd_enable();
	else if (strcmp(argv[0], "disable") == 0)
		return cmd_disable();
	else if (strcmp(argv[0], "status") == 0)
		return cmd_status();
	else if (strcmp(argv[0], "delay") == 0)
		return cmd_delay(argc - 1, argv + 1);
	else {
		fprintf(stderr, "Error: Unknown command '%s'\n\n", argv[0]);
		print_usage();
		return 1;
	}
}
