# ct_nsclc import
```dbeaver
@set cancer_type=NSCLC
@set cancer_type_icd=^(C34|162)
```

```bash
source util/util.sh
export cancer_type='NSCLC'
export cancer_type_icd='^(C34|162)'
psql_w_envs caregiver/icd_physician.sql
```


