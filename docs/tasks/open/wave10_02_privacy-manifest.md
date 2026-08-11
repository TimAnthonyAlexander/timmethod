# W10-02 · Privacy manifest and required reasons

**Wave:** 10 — Ship Readiness
**Status:** open
**Depends on:** W1-01
**Spec:** §17

## Goal
`PrivacyInfo.xcprivacy` complete and correct.

## Why
Missing required-reason declarations throw ITMS-91053 and block upload outright. This is a mature, strictly enforced gate, not a new risk.

## Do
- [ ] Declare required-reason API usage: UserDefaults, file timestamp APIs, disk space APIs, system boot time if used
- [ ] Declare collected data types — should be none, given on-device-only processing
- [ ] Audit any third-party SDK's own manifest; they trip required reasons transitively through the bundle
- [ ] Verify no analytics SDK can reach set data (guidelines 5.1.3(i) and 5.1.2(vi))
- [ ] Validate by attempting an actual upload to App Store Connect, even if never released

## Done when
- [ ] Upload validation passes with no ITMS-91053
- [ ] The manifest declares no data collection, and that is true
- [ ] A dependency audit is recorded

## Notes
Health, fitness and body-pose-derived data may not be used for advertising, marketing or data mining, including by third parties. The simplest way to comply is to ship no analytics at all, which is also the correct decision here.
