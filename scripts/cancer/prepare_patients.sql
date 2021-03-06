/***
Requires:
    prod_msdw.all_labs
    prod_references
    dev_patient_info_${cancer_type}
    dev_patient_clinical_${cancer_type}
Results:
    demo
    loh, latest_lot_drug
    latest_icd, latest_lab
    latest_ecog, latest_karnofsky
    vital, vital_bmi
Setttings:
    @set cancer_type=
*/
-- icds. labs, etc to limit by last three years?
set search_path=ct_${cancer_type};

/***
 * demo
 * todo: require last visit within 3 years
 */
drop table if exists demo cascade;
create table demo as
select distinct person_id, date_of_birth, gender_name, date_of_death, race_name, ethnicity_name
from cplus_from_aplus.cancer_diagnoses cd
join prod_references.cancer_types using (cancer_type_id)
join prod_references.people p using (person_id)
join prod_references.genders g using (gender_id)
join prod_references.races r using (race_id)
join prod_references.ethnicities using (ethnicity_id)
join cplus_from_aplus.visits using (person_id)
where nvl(cd.status, '') != 'deleted' and nvl(p.status, '') != 'deleted'
    and date_of_death is NULL
    and datediff(day, visit_date, current_date) <= 365.25*3
    and cancer_type_name='${cancer_type}'
;

create or replace view cohort as select distinct person_id from demo;

-- demo with zip
drop table if exists demo_plus cascade;
create table demo_plus as
select *
from (select d.*, address_zip, active_flag
    , row_number() over (
        partition by person_id
        order by active_flag)
    from demo d
    join prod_references.person_mrns pm using(person_id)
    left join prod_msdw.d_person dp on dp.medical_record_number = pm.mrn)
where row_number=1
; --without left join, will lose persons
 --active_flag='Y'
-- replace with caregiver
create or replace view v_demo_w_zip as
select distinct person_id+3040 as person_id, d.gender_name
, date_trunc('month', d.date_of_birth)::date date_of_birth_truncated
, case when d.race_name='Not Reported' then
    'Unknown' else d.race_name end as race_name
, d.ethnicity_name
, d.address_zip
from demo_plus d
order by person_id
;
/*qc
select count(*), count(distinct person_id) from demo;
    --13774
select count(*), count(distinct person_id) from demo_plus
-- where active_flag='Y'
;
select count(*), count(distinct person_id) from v_demo_w_zip
;
create or replace view ct_pca.v_debug_irregular_zip as
select person_id+3040 as person_id
, dz.address_zip zip_reported
, address_country, address_city, dp.address_zip, active_flag
from ct_pca.demo_new dz
join prod_references.person_mrns using (person_id)
join (select distinct medical_record_number mrn, citizenship
    , address_country, address_city, address_zip, active_flag, valid_flag
    from prod_msdw.d_person) dp using (mrn)
where nvl(dz.address_zip, '') !~ '^[-0-9]{3,}$' or dz.address_zip ~ '^0+$'
order by person_id, active_flag, dp.address_zip;

select address_zip from demo_new
where nvl(address_zip, '') !~ '^[-0-9]{3,}$' or address_zip ~ '^0+$'
;
*/

/***
* diagnosis
*/
drop table if exists latest_icd;
create table latest_icd as
with _all_dx as (
    select distinct person_id, dx_date, icd, icd_code, description
    from (select medical_record_number mrn, dx_date
        , icd, context_diagnosis_code icd_code, description
        from dev_patient_info_${cancer_type}.all_diagnosis) d
    join cplus_from_aplus.person_mrns using (mrn)
    join demo using (person_id)
)
select person_id, icd_code, icd as context_name, description, dx_date
from (select *, row_number() over (
        partition by person_id, icd_code
        order by dx_date desc nulls last, description)
    from _all_dx
    )
where row_number=1
;
/*qc
select count(distinct person_id) from _all_dx; --v1:4997 v2:5430 v3:3446
select count(*) from latest_icd; --v1: 316791, v2: 327904 v3: 199662
*/

/***
 * performance: no conversions
 */
drop table if exists latest_ecog;
create table latest_ecog as
select person_id, ecog_ps
, performance_score_date::date as performance_score_date
from (select *, row_number() over (
        partition by person_id
        order by performance_score_date desc nulls last, ecog_ps) --tie-breaker: best performance
    from cplus_from_aplus.performance_scores
    join demo using (person_id)
    where ecog_ps is not null)
where row_number=1
;
--select count (person_id) from latest_ecog where ecog_ps>=3; --55
drop table if exists latest_karnofsky;
create table latest_karnofsky as
select person_id, karnofsky_pct
, performance_score_date::date as performance_score_date
from (select *, row_number() over (
        partition by person_id
        order by performance_score_date desc nulls last, -karnofsky_pct) --tie-breaker: best performance
    from cplus_from_aplus.performance_scores
    join demo using (person_id)
    where karnofsky_pct is not null)
where row_number=1
;
/*qc
select ecog_ps, count(distinct person_id)
from latest_ecog
group by ecog_ps
order by ecog_ps
;
select karnofsky_pct, count(distinct person_id)
from latest_karnofsky
group by karnofsky_pct
order by karnofsky_pct
;
*/

/***
* cancer_dx using {cancer_type}
* demo, stage, histology
, gleason, psa
*/

/***
* lot: including mrn deduplicate
*/

/*** later: use lot from cplus
create table line_of_therapy as
select person_id
, drug_generic_name as drugname
, to_date(year_of_medication || '-' || month_of_medication || '-' || day_of_medication, 'YYYY-MM-DD') as drug_date
, line_of_therapy as lot
select count(distinct person_id)
from demo
join cplus_from_aplus.medications m using (person_id)
join cplus_from_aplus.line_of_therapies l using (medication_id) --2223
--join cplus_from_aplus.cancer_drugs using (drug_id, cancer_type_id)  -- only 65 upto here, stop ask for help later.
join cplus_from_aplus.drugs using (drug_id) --2223
join cplus_from_aplus.cancer_types using (cancer_type_id)
where cancer_type_name='PCA'  --2029
    and nvl(m.status, '')!='deleted' and nvl(l.status, '')!='deleted'
;

select distinct status from cplus_from_aplus.line_of_therapies;
select distinct status from cplus_from_aplus.medications;
select count(distinct person_id) from line_of_therapy;  --1615
--drop table line_of_therapy;
*/


/***
* labs
*/
drop table if exists loinc_lab;
create table loinc_lab as
select distinct person_id, result_date::date
, loinc_code, loinc_display_name
, value_float, value_range_low, value_range_high, unit
, source_value, source_unit
from prod_msdw.all_labs
join demo using (person_id)
where loinc_code is not null
    and value_float is not null
;

drop table if exists latest_lab;
create table latest_lab as
select person_id, result_date
, loinc_code, loinc_display_name
, value_float, unit
, source_unit, source_value
from (select *, row_number() over (
        partition by person_id, loinc_code
        order by result_date desc nulls last, value_float desc nulls last)
        from loinc_lab)
where row_number=1
order by person_id, result_date, loinc_code
;

/*** qc
create table _all_loinc as
select distinct loinc_code, loinc_display_name, unit
from latest_lab
;

select count(distinct person_id) from latest_lab; --11417
select * from _all_loinc where lower(loinc_display_name) ~ 'testosterone'; --'prostate';
*/

