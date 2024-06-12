-- Test to ensure ANALYZE was executed on the target cluster during finalize.

CREATE TABLE p3_sales (id int, year int, month int, day int,
region text)
DISTRIBUTED BY (id)
PARTITION BY RANGE (year)
    SUBPARTITION BY RANGE (month)
       SUBPARTITION TEMPLATE (
        START (1) END (2) EVERY (1),
        DEFAULT SUBPARTITION other_months )
           SUBPARTITION BY LIST (region)
             SUBPARTITION TEMPLATE (
               SUBPARTITION usa VALUES ('usa'),
               DEFAULT SUBPARTITION other_regions )
( START (2002) END (2003) EVERY (1),
  DEFAULT PARTITION outlying_years );
insert into p3_sales values (1, 2002, 1, 20, 'usa');
insert into p3_sales values (1, 2002, 1, 20, 'usa');
