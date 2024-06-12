-- Test to ensure ANALYZE was executed on the target cluster during finalize.

select relname, reltuples, relpages from pg_class where relname like 'p3_sales%' order by relname;
select * from pg_stats where tablename like 'p3_sales%' order by tablename, attname;
select pgc.relname from pg_stat_last_operation pgl, pg_class pgc where pgl.objid=pgc.oid and pgc.relname like 'p3_sales%' and staactionname='ANALYZE' order by pgc.relname;
