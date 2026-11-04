# Module 25 Exercises — Multi-Vari / Variance Components

All numeric answers re-derivable from `data/multivari-bore.csv` via
`scripts/derive_keys.py`.

## E1
Name the three families sampled in this design and give the levels of each. How many
observations per pc level, and why is balance essential to the variance-component
formula?

## E2
Compute the grand mean and the CENTERED SST from the data. A teammate reports
"TSS = 5862.07" — diagnose precisely what they computed and what the correct value is.

## E3
Compute eta^2 for the positional family from SSB/SST and interpret it in plain
language for the plant manager.

## E4
For the spindle family: report MSB, MSW, F, and the variance components. Why does
sigma2_family clamp at 0, and what would an un-floored negative component have
"claimed" about the population?

## E5
Show that eta^2 (89.1%) and the component-based share (90.0%) for the positional
family agree to within ~1 point, and explain in one sentence why they are not
identical quantities.

## E6
The multi-vari chart shows pc means stepping -1.38 -> 18.42 um with within-cell
s = 2.62 um. If positional variation were pure noise, roughly what endpoint spread
would you expect? Compare with the observed 19.79 um.

## E7
Decision: the team proposes attacking spindle-to-spindle variation first because "3
machines are easier to fix than a fixture". Using the derived F values, write the
3-sentence refusal memo citing the numbers.

## E8 (stretch)
If a future dataset added a real spindle effect of sigma_s = 3 um per spindle mean,
what would you expect MSB for spindle to become (approx.), given MSW ~ 6.9 in the
reduced-noise world where positional variance is engineered away? Use
E[MSB] = sigma2_within + m * sigma2_family with m = 15.
