# Required Fix Validation Summary

- mode: `runtimeorder`
- focus: `all`
- generated: `2026-07-22 13:31:14`

- pass: 6
- xfail: 0
- fail: 0

| scenario_id | status | message |
| --- | --- | --- |
| runtime_order_contract | pass | Runs G5S3R4 twice in each TW order. With WritePdf=false, wall_s is simulation plus MAT overhead and report_wall_s is zero by construction. |
| runtime_A_TW0_TW1_G5S3R4_TW0 | pass | reversed-order-runtime G5S3R4_TW0: wall 16.49 s, rows code=40,doppler=20,carrier=40,twtt=0,islCode=2,islDoppler=2,islTwoWay=0,total=104; source=config-derived, epochs 121. |
| runtime_A_TW0_TW1_G5S3R4_TW1 | pass | reversed-order-runtime G5S3R4_TW1: wall 18.06 s, rows code=40,doppler=20,carrier=40,twtt=5,islCode=2,islDoppler=2,islTwoWay=0,total=109; source=config-derived, epochs 121. |
| runtime_B_TW1_TW0_G5S3R4_TW1 | pass | reversed-order-runtime G5S3R4_TW1: wall 15.88 s, rows code=40,doppler=20,carrier=40,twtt=5,islCode=2,islDoppler=2,islTwoWay=0,total=109; source=config-derived, epochs 121. |
| runtime_B_TW1_TW0_G5S3R4_TW0 | pass | reversed-order-runtime G5S3R4_TW0: wall 14.97 s, rows code=40,doppler=20,carrier=40,twtt=0,islCode=2,islDoppler=2,islTwoWay=0,total=104; source=config-derived, epochs 121. |
| runtime_order_interpretation | pass | mean TW0 15.73 s, mean TW1 16.97 s, delta 7.9%. Do not infer TW1 is physically cheaper from a single order; compare both orders with row counts and PDF disabled. |
