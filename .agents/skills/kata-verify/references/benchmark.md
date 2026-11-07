# Verify a performance claim

Use this method only for a measured speed, throughput, latency, memory, or
regression claim. Write the exact claim before the run. For a user-requested
ballpark, one run is enough, but label it as one run and still check errors and
that the measured work happened.

Check each condition with run evidence:

1. **Limiter:** Name the CPU, I/O, lock, memory, network, service, or load-driver
   limit that prevents a result twice as good. Profile in a separate run because
   the profiler can change the reported result.
2. **Tuning:** Use production-equivalent builds, versions, data, batching,
   pools, cache state, and relevant settings for each side. An untuned side
   cannot support a winner.
3. **Physical limits:** Compare the result with core count, bandwidth, work per
   operation, and the measured share of the changed part. A result beyond these
   limits measured different work, a cache, a no-op, or an error.
4. **Errors and output:** Count failures, timeouts, retries, and non-success
   responses. Check correct output, not only output presence.
5. **Repeatability:** For a choice between options, run each side at least five
   times in alternating order. Report the median and range. A gap smaller than
   run variation is no measurable difference.
6. **User relevance:** Measure the end-to-end path with realistic data and
   concurrency. State the measured part as a share of that path.
7. **Executed work:** Prove that the timed region performed and used the work.
   Check requests, rows, bytes, iterations, awaited results, or another direct
   effect.

Return faster, slower, no measurable difference, or inconclusive. Report the
number, unit, run count, range, limiter, workload, and missing condition. Use
inconclusive when the limiter is unknown, one side is untuned, errors were not
checked, or executed work was not proved.
