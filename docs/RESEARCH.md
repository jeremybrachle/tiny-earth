# Research

## Executive Summary

Tiny Semantic Earth frames a question at the intersection of cartography, cognitive science, and game design: how many geographic features does it take for a human to recognize a globe as Earth? The project proposes that a *recognizability threshold* exists, is measurable, and can be approximated with a data-driven scoring function that ranks features by population, cultural prominence, geographic uniqueness, and transport connectivity. The core artifact is a semantic compression engine — a Python data pipeline — that ranks real-world features and projects only the survivors onto a walkable toy planet. If the hypothesis holds, the resulting interactive experience serves as empirical evidence that geographic meaning can be compressed far below the information density of conventional maps.

---

## Background

Traditional cartographic generalization is concerned with visual fidelity: simplifying geometry, resolving label conflicts, and preserving spatial accuracy as map scale changes. The goal is to produce a map that looks like the original at a lower resolution. This project asks a different question: not "does it look accurate?" but "does a human still recognize it?"

*Semantic compression* in this context means retaining only those geographic features that contribute the most to human recognition — discarding everything else regardless of spatial accuracy. A river that no one has heard of may be geographically significant on a conventional map; here it scores zero. The Eiffel Tower, which occupies a negligible footprint on Earth's surface, scores near the top because it instantly disambiguates location for almost any observer.

This is the distinction between map generalization and semantic compression: generalization preserves spatial structure, semantic compression preserves cognitive salience. The two are not the same, and no existing GIS tool optimizes for the latter.

---

## Core Hypothesis

Geographic features vary enormously in their contribution to a viewer's ability to recognize and orient on Earth. A small subset — major capitals, prominent coastlines, a handful of globally iconic landmarks — carries a disproportionate share of the recognizability signal. The formal hypothesis:

> There exists a minimum feature set F\* ⊆ F_all such that for any feature set F where |F| ≥ |F\*|, human geographic recognition accuracy exceeds threshold θ. Below |F\*|, accuracy drops sharply.

More precisely, the project predicts a **recognizability curve**: a function R(n) mapping the number of retained features n to the probability that a naive observer correctly identifies their location. The curve is expected to be sigmoidal — flat at very low n, rising steeply through a critical range, then plateauing near ceiling. The inflection point of that curve is the *semantic compression threshold* the project is trying to locate.

---

## Scoring Formula

Each candidate feature is assigned a composite importance score:

```
score(f) = (w_pop  × log(population(f) + 1))
         + (w_sal  × cultural_salience_index(f))
         + (w_uniq × geographic_uniqueness(f))
         + (w_conn × transport_hub_rank(f))
```

| Variable | Type | Source | Description |
|---|---|---|---|
| `population(f)` | integer | OSM / GeoNames | Raw population of city or metro area |
| `cultural_salience_index(f)` | float [0,1] | Wikipedia Pageviews API | Normalized annual Wikipedia pageview count for the feature's article |
| `geographic_uniqueness(f)` | float [0,1] | Computed | Inverse of local feature density — isolated features score higher than clustered ones |
| `transport_hub_rank(f)` | float [0,1] | OSM / IATA | Normalized rank by airport passenger volume or major rail hub status |
| `w_pop`, `w_sal`, `w_uniq`, `w_conn` | float | `planet.yaml` | Default: **0.4 / 0.3 / 0.2 / 0.1** |

The formula is additive so that a feature scoring zero on one dimension (e.g., an uninhabited island with no Wikipedia article) is not automatically eliminated if it scores highly on geographic uniqueness. The log transform on population prevents megacities from dominating. The weight on `cultural_salience_index` is deliberately high, reflecting the assumption that cultural familiarity — not raw size — is the primary driver of recognizability.

Default weights are a starting point. The compression experiments (Phase 6 onward) tune these weights and measure their effect on the recognizability curve.

---

## Compression Ratio Concept

The **compression ratio** is defined as:

```
CR = |retained features| / |candidate features|
```

where the candidate set is the full set of OSM features within the pipeline's scope (order of magnitude: millions of named places worldwide) and the retained set is the top-N survivors after scoring. The pipeline exposes a `compression_level` parameter in `planet.yaml` that controls N directly.

Planned experiments will test across multiple compression levels from CR near 1 (everything) down to extreme compression (top 10 features), with the playable experience targeting somewhere in the range of top 50–500 features. The goal is to locate the smallest N at which the globe remains recognizable — the inflection point of R(n).

The recognizability curve is expected to have a roughly sigmoidal shape: near-random accuracy at very low N, a steep rise through a critical threshold range, and a plateau near ceiling performance. Finding and characterizing that threshold is the primary research contribution.

---

## Experimental Design

**Independent variable:** Compression level (number of retained features N)

**Dependent variable:** Geographic recognition accuracy

**Task:** Show a participant a screenshot of the compressed globe at a random location. Ask:
1. "Which continent are you on?" (multiple choice: Africa, Antarctica, Asia, Australia/Oceania, Europe, North America, South America)
2. "Name the nearest city or landmark you recognize."

**Measure:** Percent correct identification at each compression level.

**Sample:** Small-n pilot study, 10–20 participants with no prior knowledge of the project.

**Procedure:** Each participant sees the globe at multiple compression levels (e.g., N = 10, 25, 50, 100, 200, 500), randomized order, with location randomized per trial. Record accuracy, response time, and self-reported confidence per trial.

**Expected result:** Accuracy near chance (~14% for 7 continents) at N ≤ 10, rising steeply between N = 25–100, plateauing above 80% at N ≥ 200–500.

**Limitations:** Self-selection bias (participants likely have higher-than-average geographic literacy), small sample size, and continent-level accuracy as a coarse proxy. Future work could use finer-grained region identification or eye-tracking.

---

## Research Framing

**Working title:** *"Semantic Compression of Geographic Information for Interactive Playable Worlds"*

**Venue targets:** IEEE VIS (short paper or alt track), ACM CHI (alt.CHI or late-breaking work), GIScience, or CHI Play.

**Novel contributions:**
1. The scoring formula — a reproducible, data-driven method for ranking geographic features by cognitive salience rather than spatial accuracy
2. The recognizability curve — an empirical, interactive measurement of the geographic information minimum
3. The playable artifact — a demonstration that semantic compression produces a navigable, recognizable experience at extreme compression ratios

Existing work on geographic generalization (cartographic line simplification, map scale selection, landmark salience for wayfinding) focuses on visual fidelity and spatial accuracy. This work proposes *cognitive recognizability* as a complementary axis and operationalizes it through an interactive artifact rather than a static map.

---

## Open Questions and Future Directions

1. **Does the optimal feature set vary by culture?** The current scoring function uses English-language Wikipedia pageviews, which skews toward features prominent in English-language media. Aggregating across multiple language editions (Spanish, Mandarin, Arabic, French, Russian) would reduce this bias — but would it produce a materially different feature ranking?

2. **What is the minimum landmark set vs. minimum terrain set?** The formula currently treats cities and iconic landmarks the same way. It's plausible that terrain features (coastline shape, mountain ranges) carry more recognizability signal at low N, while landmarks dominate at mid-N. Separating these two signals and measuring their independent contributions would sharpen the research.

3. **Can the pipeline generalize to fictional or historical worlds?** The scoring function is Earth-specific because it depends on population counts and Wikipedia article existence. Could an analogous function be defined for a fictional planet using only geographic uniqueness and topological properties?

4. **Can ML replace the hand-tuned scoring formula?** The current formula is an explicit model with hand-set weights. A learned model trained on human recognition data could potentially discover a more accurate weighting. This would require a reasonably large user study dataset as a training signal.

5. **Semantic LOD:** Could the compression ratio adapt in real time based on the player's location — higher feature density near the player, lower on the far side of the globe? This would be a form of *semantic level of detail*, analogous to geometric LOD in conventional game engines.
