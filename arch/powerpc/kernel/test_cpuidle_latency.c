// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Module-based API test facility for cpuidle latency using IPIs and timers
 */

#include <linux/debugfs.h>
#include <linux/kernel.h>
#include <linux/module.h>

/*
 * IPI based wakeup latencies
 * Measure time taken for a CPU to wakeup on a IPI sent from another CPU
 * The latency measured also includes the latency of sending the IPI
 */
struct latency {
	unsigned int src_cpu;
	unsigned int dest_cpu;
	ktime_t time_start;
	ktime_t time_end;
	u64 latency_ns;
} ipi_wakeup;

static void measure_latency(void *info)
{
	struct latency *v = (struct latency *)info;
	ktime_t time_diff;

	v->time_end = ktime_get();
	time_diff = ktime_sub(v->time_end, v->time_start);
	v->latency_ns = ktime_to_ns(time_diff);
}

void run_smp_call_function_test(unsigned int cpu)
{
	ipi_wakeup.src_cpu = smp_processor_id();
	ipi_wakeup.dest_cpu = cpu;
	ipi_wakeup.time_start = ktime_get();
	smp_call_function_single(cpu, measure_latency, &ipi_wakeup, 1);
}

/*
 * Timer based wakeup latencies
 * Measure time taken for a CPU to wakeup on a timer being armed and fired
 */
struct timer_data {
	unsigned int src_cpu;
	u64 timeout;
	ktime_t time_start;
	ktime_t time_end;
	struct hrtimer timer;
	u64 timeout_diff_ns;
} timer_wakeup;

static enum hrtimer_restart hrtimer_callback(struct hrtimer *hrtimer)
{
	struct timer_data *w;
	ktime_t time_diff;

	w = container_of(hrtimer, struct timer_data, timer);
	w->time_end = ktime_get();

	time_diff = ktime_sub(w->time_end, w->time_start);
	time_diff = ktime_sub(time_diff, ns_to_ktime(w->timeout));
	w->timeout_diff_ns = ktime_to_ns(time_diff);
	return HRTIMER_NORESTART;
}

static void run_timer_test(unsigned int ns)
{
	hrtimer_init(&timer_wakeup.timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	timer_wakeup.timer.function = hrtimer_callback;
	timer_wakeup.src_cpu = smp_processor_id();
	timer_wakeup.timeout = ns;
	timer_wakeup.time_start = ktime_get();

	hrtimer_start(&timer_wakeup.timer, ns_to_ktime(ns),
		      HRTIMER_MODE_REL_PINNED);
}

static struct dentry *dir;

static int cpu_read_op(void *data, u64 *dest_cpu)
{
	*dest_cpu = ipi_wakeup.dest_cpu;
	return 0;
}

/*
 * Send a directed IPI from the current CPU (source) to the destination CPU and
 * measure the latency on wakeup.
 */
static int cpu_write_op(void *data, u64 value)
{
	run_smp_call_function_test(value);
	return 0;
}
DEFINE_SIMPLE_ATTRIBUTE(ipi_ops, cpu_read_op, cpu_write_op, "%llu\n");

static int timeout_read_op(void *data, u64 *timeout)
{
	*timeout = timer_wakeup.timeout;
	return 0;
}

/* Queue a hrtimer on a specified desitination CPU and measure the time taken to
 * wakeup the CPU.
 */
static int timeout_write_op(void *data, u64 value)
{
	run_timer_test(value);
	return 0;
}
DEFINE_SIMPLE_ATTRIBUTE(timeout_ops, timeout_read_op, timeout_write_op, "%llu\n");

static int __init latency_init(void)
{
	struct dentry *temp;

	dir = debugfs_create_dir("latency_test", arch_debugfs_dir);
	if (!dir) {
		pr_alert("latency_test: failed to create /sys/kernel/debug/powerpc/latency_test\n");
		return -1;
	}
	temp = debugfs_create_file("ipi_cpu_dest", 0644, dir, NULL, &ipi_ops);
	if (!temp) {
		pr_alert("latency_test: failed to create /sys/kernel/debug/powerpc/ipi_cpu_dest\n");
		return -1;
	}
	debugfs_create_u64("ipi_latency_ns", 0444, dir, &ipi_wakeup.latency_ns);
	debugfs_create_u32("ipi_cpu_src", 0444, dir, &ipi_wakeup.src_cpu);

	temp = debugfs_create_file("timeout_expected_ns", 0644, dir, NULL, &timeout_ops);
	if (!temp) {
		pr_alert("latency_test: failed to create /sys/kernel/debug/powerpc/timeout_expected_ns\n");
		return -1;
	}
	debugfs_create_u64("timeout_diff_ns", 0444, dir, &timer_wakeup.timeout_diff_ns);
	debugfs_create_u32("timeout_cpu_src", 0444, dir, &timer_wakeup.src_cpu);
	pr_info("Latency Test module loaded\n");
	return 0;
}

static void __exit latency_cleanup(void)
{
	pr_info("Cleaning up Latency Test module.\n");
	debugfs_remove_recursive(dir);
}

module_init(latency_init);
module_exit(latency_cleanup);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("IBM Corporation");
MODULE_DESCRIPTION("Measuring idle latency for IPIs and Timers");
