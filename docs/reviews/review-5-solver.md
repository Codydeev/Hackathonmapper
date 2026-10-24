# Review 5: LayoutSolver / MeshLocator (numerical methods)

Source: `origin/feature/map-accuracy` (87b2f6c). The local checkout is `main`, so all files were read with `git show`. Python port and stress scripts: `scratchpad/r5/layout.py`, `stress.py`, `stress2.py`, `stress3.py`, `stress4.py`. The port reproduces every LayoutSolverTests expectation: exact ranges converge to 4e-9 m, the one-range rel σ is 100, the bearing swings round from all four starts, and the loose-GPS midpoint is (2, 0.5).

## Verdict: C+

`LayoutSolver` is numerically sound. Over roughly 600 solves (degenerate inputs, 20 phones, churn, NLOS) I saw no NaN or inf, no Cholesky failure, and cond(info) never above 1e4. The Jacobians for range, log-RSSI and bearing are correct. The curvature ("stretch") term is the correct ρ'(r)·∇²r for r > 0 and is PSD, and it cuts iteration-cap hits from 81 to 56 out of 120. The gauge is handled without bias: the regularization goes on the step only and caps σ at 100 m. The main problem is in `MeshLocator`. The temporal prior feeds the previous **marginal** σ back each tick as an independent per-phone prior. That double-counts information. Over time it invents geometry that nothing measured, so an unresolvable rotation is drawn as a confident dot, and every σ / r95 comes out 2–6× too small. This breaks the product rule ("direction unknown → ring, never presented as measured"), so the grade is held back.

## Findings

**1. The temporal prior fabricates certainty (High, confidence high).** MeshLocator.swift:227-232 together with :285-289.
- **Problem:** the previous solution's larger-axis marginal variance comes back as an isotropic, independent prior on every phone, and the GPS prior is added again each tick as if it were new evidence. Cross-phone correlations are thrown away, so N rigidly linked phones each add the same rotational information again.
- **Scenario:** one GPS phone `g` and lost phones x and y in a UWB triangle. The rotation about g is unobservable. At tick 5 both are rings (rel 8.6). From tick 30 on, both are **dots with rel σ 2.2 m**, at whatever angle the golden-spiral seed picked (stress2 A2). In a 4-phone chain, p1's rel σ drifts from 6.2 to 3.2, right at the threshold of 3.
- **Fix:** keep the warm start, but compute the covariance, and therefore σ, r95 and `unresolved`, from normal equations **without** the temporal priors. A cheaper alternative is to store the full previous covariance and add (Σ_prev + Q)⁻¹ as one joint prior. Add a test: one GPS phone plus a rigid UWB triangle must still be a ring after 60 ticks.

**2. σ / r95 are overconfident even when the geometry is resolved (High, confidence high).** Same lines.
- **Problem:** with two GPS phones (declared 5 m) whose errors are bias plus 1 m jitter, the reported σ is 2.47 m while the real RMS error is 4.66 m. The steady state of v = σg²(v+w²)/(v+σg²+w²) assumes GPS errors are independent from one second to the next, and they are not.
- **Scenario:** in the 20-phone scene, err/σ has a median of **2.3–6.3** with the temporal prior and **0.7–1.0** with a fresh locator each tick. A gpsRefined r95 circle routinely misses the truth.
- **Fix:** the fix for #1 covers it. In addition, floor the gpsRefined σ at about 0.5·accuracy.

**3. The covariance ignores residual inconsistency (Medium, confidence high).** LayoutSolver.swift:188-196.
- **Problem:** Huber only bounds influence. With 2 of 4 UWB ranges 3 m long (body NLOS), the error is 3.7 m but σ = 0.37 m. With 6 m bias the error is 6.4 m and σ = 0.34 m. A single outlier is handled well, at an error of 0.3–0.5 m.
- **Fix:** inflate the covariance by max(1, 2·cost/dof), or by the per-phone sum of down-weighted residuals. Optionally do a final redescending pass (Tukey/Cauchy) from the Huber solution.

**4. Convergence is often truncated (Medium, confidence medium).** LayoutSolver.swift:149 (maxIterations 30) and :177-185.
- **Problem:** in the 20-phone churn scene, 56 of 120 ticks hit the 30-iteration cap, with a final |g| up to 19. The covariance is then evaluated at a non-stationary point. Raising the cap to 300 lowers this to 5 of 120 but barely changes the error. The warm start hides the problem.
- **Scenario:** a cold start after a phone joins draws a half-converged layout for a few seconds. Jumps beyond the true motion reached 10–17 m on non-ring dots, which looks like flips between local minima when links change.
- **Fix:** accept a step on a relative cost decrease and stop on ‖g‖∞ < 1e-3 or a relative cost change < 1e-6. Allow about 100 iterations on a cold start, which still costs well under 5 ms at m = 40.

**5. A mirror seed on the baseline sits on a saddle (Low–Medium, confidence medium).** MeshLocator.swift:249-251.
- **Problem:** the seed points toward the particle filter's estimate. For a two-spot (mirror) belief that estimate is the mean, which lies on the anchor baseline. A start exactly on the A–B line converges to the symmetric saddle (4.28, 0), with rel σ 100, and stays there, because noise in the ranges cannot break the symmetry.
- **Scenario:** it shows as a ring, so it is not wrong, but the point never resolves when the third link arrives later only as RSSI.
- **Fix:** when `estimate.ambiguous`, seed toward a cloud sample or the ring point, or add a small perpendicular offset.

**6. The manual/UWB clamp runs after the solve (Low, confidence high).** MeshLocator.swift:278-284.
- **Problem:** the clamp moves the anchor, but its neighbours were solved against the unclamped point, so drawn link lengths no longer equal the measured ones. `previous` also stores the clamped point.
- **Fix:** a manual σ of 0.3 already makes the clamp almost a no-op. Either accept this, or re-solve the lost phones once with the clamped anchors fixed.

**7. A parallel link inflates the iteration count (Low, confidence medium).** A degenerate `range 1e4` case crawls to the cap: after 30 iterations x is only at 2002 m. That cannot happen with real UWB (under 50 m), but it shows that small LM steps crawl when the Huber linear region is large. No action needed beyond #4.

## What is done well
- Each term carries its own σ, as the design's table specifies: UWB 0.15 + 0.02d, RSSI in log-distance with a flat-zone zero slope, bearings with a wrapped residual.
- The stretch Hessian is a clever and correct fix for crawling stretched pairs.
- `relativeSigma` (the vector covariance including cross terms) is the right quantity for the ring decision, better than the design's marginal σ.
- Defensive code throughout: coincident phones get a push direction, `isFinite` guards, a σ floor of 1e-3, Cholesky failure leads to λ×10, and the inverse falls back to 1/reg.
- Performance is fine: m ≤ 40, so dense Cholesky plus the inverse is about 150 kflop. Per-term array allocations (`entries`, `t`) add perhaps 1–3 ms per tick in Swift. The particle filter, not the solver, will dominate the 1 Hz main-thread budget.

## Phone verification
1. One GPS phone and two UWB phones held in a fixed triangle, idle for 60 s: x and y must remain rings, not dots (catches #1).
2. Two GPS phones 3 m apart, walked together for 2 min: the 3.0 m UWB label holds, and the gpsRefined circle should cover the true spot. Compare it with a surveyed point (#2).
3. Put a body between two of four UWB phones: watch whether the r95 circle grows (#3).
4. Have a phone join a 10-phone group: no dot should jump more than 3 m between ticks once links are up (#4).
5. Measure the time of `locator.update` with 15–20 phones in Instruments. The budget is under 50 ms.
