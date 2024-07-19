# gpupgrade internal workflow with pg_upgrade

**Goal**: The purpose of this README is to capture the process of how in-place
upgrade is done in pg_upgrade. By the end of this README the goal is that a
reader would have an understanding of how pg_upgrade is used by gpupgrade to
perform in-place-upgrades and understand the changes we have done to make it
work for GPDB. The intended audience for this document is an engineer with
general GPDB knowledge onboarding onto the pg_upgrade project. We also want to
take this oppurtunity to capture context on how things ended up the way they
did so we can find ways to make the process less complicated and improve on.

## pg_upgrade's original workflow
[pg_upgrade](https://www.postgresql.org/docs/12/pgupgrade.html) allows data
stored in data files to be upgraded to a later database major version without
the data backup/restore typically required for major version upgrades. The new
major version's pg_upgrade binary is used to perform the upgrade from the old
cluster. At a high level pg_upgrade does the following:
1. Check for cluster compatibility
1. Use pg_dumpall to dump old cluster schema (no data)
1. Freeze all new cluster rows (to remove reference to clog entries)
1. Copy control file settings to new cluster (clog, xlog, xid)
1. Recreate database and schemas on new cluster using pg_restore
1. Copy or link files (relfilenodes) to new cluster


More about pg_upgrade implementation can be found here:<br>
https://github.com/greenplum-db/gpdb/blob/6X_STABLE/contrib/pg_upgrade/IMPLEMENTATION


## pg_upgrade's modified workflow for GPDB
#### pg_upgrade check on coordinator
1. Check for coordinator compatibility.

#### pg_upgrade on coordinator
1. Check for coordinator compatibility
1. Use pg_dumpall to dump old cluster schema (no data)
1. Freeze all new cluster rows to remove references to clog entries
1. Copy control file settings to new coordinator (clog, xlog, xid)
1. Recreate database and schemas on new coordinator using pg_restore
1. Copy or link files (relfilenodes) to new cluster
1. Set new coordinator's frozenxid and minmxid
1. Freeze new coordinator to make everything visible for segments
1. Invalidate bpchar_pattern_ops, bitmap, and AO indexes

### \*\*\*gpupgrade: COPY coordinator to segments to bootstrap segment upgrade\*\*\*

#### 2nd pg_upgrade call against each segment
1. Check segment for compatibility (same checks that are run on coordinator)
1. Freeze all new cluster rows to remove references to clog entries
1. Copy control file settings to new cluster (clog, xlog, xid)
1. Set coordinator's frozenxid and minmxid
1. Set coordinator's frozenxid and minmxid again
1. Copy or link files (relfilenodes) to new cluster
1. Reset system identifier

## How gpupgrade uses pg_upgrade in it's workflow
gpupgrade is GPDB's utility for performing in-place upgrades. At a high level
gpupgrade uses pg_upgrade in the following manner:
1. gpugprade initialize
    1. Generate and execute data migration SQL scripts
    1. Configure target cluster
    1. Run pg_upgrade checks
1. gpugprade execute
    1. Run pg_upgrade to upgrade the coordinator
    1. Copy the upgraded coordinator to each segment. We use the upgraded
       coordinator to bootstrap segment upgrade.
    1. Run pg_upgrade to upgrade the segments
1. gpupgrade finalize
    1. execute data migration finalize scripts

## GPDB pre-upgrade checks
GPDB adds additional checks during pre-upgrade to ensure the smooth gpupgrade
experience. A lot of the checks are just queries against the source cluster,
but some are more in depth. The prime example here are view checks. Postgres
does not check views for issues that could cause a failure, but they can fail
for a variety of reasons such as using removed functions, operators, types.
View checks requires installing pg_upgrade support functions on the source
cluster.

Example 6 > 7 view check for removed types
| Commit | Link |
| -------- | ------- |
| Support function is commited to 6X | https://github.com/greenplum-db/gpdb/pull/17187    |
| Check that uses support function is commited to 7X | https://github.com/greenplum-db/gpdb/pull/17188     |
| Test that excercises the check | https://github.com/greenplum-db/gpupgrade/pull/903 |



## Data Migration SQL scripts
There are cases where some objects have configurations that are not valid on a
target cluster, but can be fixed with a bit a tweaking or just by remaking
them.  To make migration as easy as possible for customers we may generate
scripts that fix user objects to make them upgradable. Some scripts run during
initialize. These will typically be scripts that fix objects or drop non
upgradable objects. Some scripts will run during finalize step. These scripts
may do things like recreate unique constraints which is faster after data is in the
database. We also generate revert scripts to revert objects back to their
original structure if applicable and `gpupgrade revert` is run. As of today
data migration scripts are generated in gpupgrade.

Learn more about these here:
https://github.com/greenplum-db/gpupgrade/tree/main/data-migration-scripts

## pg_upgrade execution visualized
```
pg_upgrade executed on coordinator
main
├── check_and_dump_old_cluster
│   ├── generate_old_tablespaces_file(&old_cluster);
│   ├── get_db_and_rel_infos(&old_cluster)
│   │   ├── get_db_infos
│   │   └── get_rel_infos
│   ├── set_old_cluster_chkpnt_oldstxid
│   ├── check_greenplum
│   └── generate_old_dump
│       ├── pg_dumpall --globals-only
│       └── pg_dumps
├── check_new_cluster
│   ├── get_db_and_rel_infos(&new_cluster) // should return empty
│   └── check_loadable_libraries
├── prepare_new_cluster
│   ├── vacuumdb --all --analyze
│   └── vacuumdb --all --freeze
├── copy_clog_xlog_xid
├── prepare_new_databases
│   ├── set_frozenxids(false);  // frozenxid and minmxid
│   │   ├── UPDATE pg_database SET datfrozenxid
│   │   ├── UPDATE pg_database SET datminmxid
│   │   ├── UPDATE pg_class SET relfrozenxid
│   │   └── UPDATE pg_class SET relminmxid
│   ├── install_support_functions_in_new_db('template1')
│   ├── psql -f GLOBALS_DUMP_FILE
│   └── get_db_and_rel_infos(&new_cluster) // to get databases
├── create_new_objects
│   ├── install_support_functions_in_new_db
│   ├── pg_restores
│   ├── set_frozenxids(true) // minmxid only
│   │   ├── UPDATE pg_database SET datminmxid
│   │   └── UPDATE pg_class SET relminmxid
│   ├── get_db_and_rel_infos(&new_cluster) // get relations
│   └── uninstall_support_functions_from_new_cluster
├── transfer_all_new_tablespaces
│   └── parallel_transfer_all_new_dbs
│       └── transfer_all_new_dbs (currently serial)
│            ├── gen_db_file_maps
│            │   └── report_unmatched_relation 
│            └── transfer_single_new_db
│                ├── transfer_ao*
│                └── transfer_relfile
├── update_db_xids*
│   ├── UPDATE pg_database SET datfrozenxid, datminmxid
│   ├── UPDATE pg_class SET relfrozenxid
│   └── UPDATE pg_class SET relminmxid
├── freeze_master_data*
│   ├── VACUUM FREEZE
|   └── VACUUM FREEZE pg_catalog.pg_database
├── invalidate indexes
    ├── invalidate bpchar_pattern_ops indexes
    ├── invalidate bitmap indexes*
    └── invalidate indexes on AO tables*

* specific to GPDB
```

---

### \*\*\*COPY MDD to segments to bootstrap segment upgrades\*\*\*

This is step is performed by gpupgrade by rysncing most of the contents of
Master Data Directory to the segments. The following files are excluded and not
copied over.
```
internal.auto.conf
postgresql.conf
pg_hba.conf
postmaster.opts
gp_dbid
gpssh.conf
gpperfmon
```

---

At this point the primaries are "upgraded" because the data directory was
copied from coordinator. This manner of upgrading a cluster is quite
unconventional and the copies of coordinators must now be converted to segments
by copying the control values from the old segment cluster.
```
pg_upgrade executed on segments
main
├── check_and_dump_old_cluster
│   ├── get_db_and_rel_infos(&old_cluster)
│   │   ├── get_db_infos
│   │   └── get_rel_infos
│   └── set_old_cluster_chkpnt_oldstxid
├── check_new_cluster
│   ├── get_db_and_rel_infos(&new_cluster)
│   │   ├── get_db_infos
│   │   └── get_rel_infos // will get all relations restored by coordinator
│   └── check_loadable_libraries
├── prepare_new_cluster
│   └── vacuumdb --all --freeze
├── copy_clog_xlog_xid
├── set_frozenxids(false);*
│   ├── UPDATE pg_database SET datfrozenxid
│   ├── UPDATE pg_database SET datminmxid
│   ├── UPDATE pg_class SET relfrozenxid
│   └── UPDATE pg_class SET relminmxid
├── update_db_xids*
│   ├── UPDATE pg_database SET datfrozenxid, datminmxid
│   ├── UPDATE pg_class SET relfrozenxid
│   └── UPDATE pg_class SET relminmxid
├── transfer_all_new_tablespaces (currently serial)
│   └── parallel_transfer_all_new_dbs
│       └── transfer_all_new_dbs
│            ├── gen_db_file_maps
│            │   └── report_unmatched_relation
│            └── transfer_single_new_db
│                ├── transfer_ao*
│                └── transfer_relfile
└── reset_system_identifier

* specific to GPDB
```

# Notable GPDB specific changes to pg_upgrade workflow

#### 1. Ensuring schema and data are visible in the new cluster
You'll notice in the diagram above showing the steps of pg_upgrade execution
pg_upgrade will run a few VACUUM FREEZE and UPDATE commands to edit frozenxid
and minmxid values. To understand why frozenxids and minmxid are being edited,
it will help to have a general understanding of how tuple visibility works in
Postgres. Here are a few resources for gettings started.

##### Resources for understanding tuple visibility:
1. Youtube video that gives an overview of the Postgres MVCC architecture. This
   talk will go into technical details around the meaning and dangers
   associated with Transaction Wrap Around and the role that Tuple Freezing
   plays in avoiding serious outage events.<br>
   https://www.youtube.com/watch?v=0RbJDP4dIi4
1. This talk will cover some key concepts of Postgres Vacuum and Autovacuum and
   some of the concepts around properly tuning Vacuum. The primary audience of
   this talk are people who have often heard of Vacuum but have never quite
   understood why it is necessary and for people who do understand Postgres
   Vacuum but have struggled to explain it.<br>
   https://www.youtube.com/watch?v=oix4am0BKII
1. Postgres documentation on transaction id wraparound failures<br>
   https://www.postgresql.org/docs/current/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND
1. Deep's initial pg_upgrade gist<br>
   https://gist.github.com/soumyadeep2007/ec4bb37ef9573ea6de138856ecbda0ce

**Note:** In PostgreSQL versions before 9.4, freezing was implemented by
actually replacing a row's insertion XID with FrozenTransactionId, which was
visible in the row's xmin system column. Newer versions just set a flag bit
(HEAP_XMIN_FROZEN), preserving the row's original xmin for possible forensic
use. However, rows with xmin equal to FrozenTransactionId may still be found in
databases pg_upgrade'd from pre-9.4 versions.

#### 1a. Freezing the coordinator after relfilenode transfer
Since segments are upgraded by copying MDD to bootstrap segment upgrade, we
must ensure that the schema is visible on segments. GPDB does this by freezing
the coordinator. Freezing must happen sometime after schema is restored in
`create_new_objects`.
```
pg_upgrade on coordinator
...
├── transfer_all_new_tablespaces
├── update_db_xids* <----- Make tuples from relfilenode transfer (pg_aoseg, aoblkdir, fastsequence) visible on coordinator, also fixes VACUUM FREEZE error.
│   ├── UPDATE pg_database SET datfrozenxid, datminmxid
│   ├── UPDATE pg_class SET relfrozenxid
│   └── UPDATE pg_class SET relminmxid
└── freeze_master_data* <----- Freeze to make schema visible on segments
    ├── VACUUM FREEZE
    └── VACUUM FREEZE pg_catalog.pg_database
```
In order to make schema on the segments visible we need to freeze the coordinator
before copying it over to segments. 

**Before:**<br>
Freezing the coordinator was first introduced in
[5583ecdeb](https://github.com/greenplum-db/gpdb/commit/5583ecdeb). It used to
be the last operation to be done before stopping the source cluster. At this
time, pg_upgrade still rebuilt pg_aoseg values using TRUNCATEs and INSERTs calls
in `restore_aosegment_tables`. Because pg_aoseg values were inserted using SQL
statements, we did not have to edit relfrozenxids and minmxids to make these
rows visible. They were then frozen to ensure they were always visible on
coordinator.

**Currrent:**<br>
The location of coordinator freeze was later changed in
[9cd8cd2630](https://github.com/greenplum-db/gpdb/commit/9cd8cd2630) to be
after relfilenode transfer. In order to fix a gp_fastsequence bug, we started
preserving the gp_fastsequence values via relfilenode transfer. To make these
fastsequence values visible for coordinator, we needed to edit their frozenxid
and minmxid. Moving coordinator freeze to after this point is a precaution for
several reasons.
1. We ensure the gp_fastsequence values are visible by freezing the coordinator
1. One of the very last steps of coordinator pg_upgrade is freezing.

The commits that changed location of coordinator freeze<br>
[c90639e6e4](https://github.com/greenplum-db/gpdb/commit/c90639e6e4) -
pg_upgrade: preserve gp_fastsequence to prevent duplicate ctids<br>
[9cd8cd2630](https://github.com/greenplum-db/gpdb/commit/9cd8cd2630) -
pg_upgrade: freeze coordinator after relfilenode transfer

#### 1b. UPDATE frozenxid and minmxids on segments
```
├── update_db_xids*
│   ├── UPDATE pg_database SET datfrozenxid, datminmxid
│   ├── UPDATE pg_class SET relfrozenxid
│   └── UPDATE pg_class SET relminmxid
```
---

#### 2. Do not preserve relfrozenxid of user tables for `pg_dump --binary-upgrade`
Normally `pg_restore --binary-upgrade` would set a table's relfrozenxid, but
we've opted for bulk edits in pg_upgrade. The dumping of relfrozenxid for user
tables is disabled in pg_dump in commit
[381c09a8072](https://github.com/greenplum-db/gpdb/commit/381c09a8072).

---

#### 3. Additional flags for pg_upgrade 

**--continue-check-on-fatal**<br>
pg_upgrade's default behavior is to exit as soon as possible when a check
fails. This means that as soon as 1 check failed, the checks after it would not
be run. We have made changes so all checks will run even if one fails. This
used to be much more relevant when checks could run for hours.

**--skip-checks**<br>
This is used to skip compatibility checks during gpupgrade execute. This is
originally put in for performance reasons. Before checks were optimized they
were very costly. There is a hidden flag, `gpupgrade executed
--skip-pg-upgrade-checks` that will skip all pg_upgrade checks.

**--skip-target-check**<br>
This flag is currently not used. This may be legacy code that does not fit into
the current workflow.

**--run-migration-checks**<br>
This is specifically for running applicable checks when upgrading using
gpbackup. Some of the checks don't apply because data on disk gets rewritten as
opposed to transferred from old cluster.

---

#### 4. Tracking AO tables in get_rel_infos
`get_rel_infos` doesn't really have anything to do with the
`check_and_dump_old_cluster`, but gets called here because we happen to have
access to the old cluster at this point. The information about the relation
infos collected here will later be used during relfilenode transfer to compare
against the objects that got restored in the the new cluster.

Additional work done in `get_rel_info` to mark AO and AOCO tables. The
information will later be used to determine if special AO relfilenode transfer
function (transfer_ao) needs to be called.
```
		/* Collect extra information about append-only tables */
		relstorage = PQgetvalue(res, relnum, i_relstorage) [0];
		curr->relstorage = relstorage;

		relkind = PQgetvalue(res, relnum, i_relkind) [0];

		if (relstorage == RELSTORAGE_AOROWS)
			curr->reltype = AO;
		else if (relstorage == RELSTORAGE_AOCOLS)
			curr->reltype = AOCS;
		else
			curr->reltype = HEAP;
```

---

#### 5. Transfer AO aux tables using relfilenode trasfer

[43e3158b38](https://github.com/greenplum-db/gpdb/commit/43e3158b38) - Fix
get_rel_infos logic to discover pg_aovisimaps on 6x

[466df4e26a](https://github.com/greenplum-db/gpdb/commit/466df4e26a) - Upgrade
AO aux tables using relfilenodes

---

#### 6. Preserve gp_fastsequence using relfile transfer

[c90639e6e4](https://github.com/greenplum-db/gpdb/commit/c90639e6e4) -
pg_upgrade: preserve gp_fastsequence to prevent duplicate ctids

---

#### 7. Set next OID before restoring schema during pg_upgrade
```
	/*
	 * GPDB: This used to be right before syncing the data directory to disk
	 * but is needed here before create_new_objects() due to our usage of a
	 * preserved oid list. When creating new objects on the target cluster,
	 * objects that do not have a preassigned oid will try to get a new oid
	 * from the oid counter. This works in upstream Postgres but can be slow
	 * in GPDB because the new oid is checked against the preserved oid
	 * list. If the new oid is in the preserved oid list, a new oid is
	 * generated from the oid counter until a valid oid is found. In
	 * production scenarios, it would be very common to have a very, very
	 * large preserved oid list and starting the oid counter from
	 * FirstNormalObjectId (16384) would make object creation slower than
	 * usual near the beginning of pg_restore. To prevent pg_restore
	 * performance degradation from so many invalid new oids from the oid
	 * counter, bump the oid counter to what the source cluster has via
	 * pg_resetxlog. If the preserved oid list logic is removed from
	 * pg_upgrade, move this step back to where it was before.
	 */
	prep_status("Setting next OID for new cluster");
	exec_prog(UTILITY_LOG_FILE, NULL, true, true,
			  "\"%s/pg_resetxlog\" --binary-upgrade -o %u \"%s\"",
			  new_cluster.bindir, old_cluster.controldata.chkpnt_nxtoid,
			  new_cluster.pgdata);
	check_ok();
```

[d1b94743b5e](https://github.com/greenplum-db/gpdb/commit/d1b94743b5e) - Set
next OID before restoring schema during pg_upgrade

## Why are segments upgraded by copying MDD to segments?
We would like to address this specific question because it is a big reason why
pg_upgrade can be complicated. Originally this was done because it was thought
that this would be more beneficial for performance. It was only later
discovered that this is likely the only way upgrade could work for 5 > 6
upgrade because segments do not contain enough schema data to dump and restore
GPDB partition tables individually. Unfortunately, this method of upgrading
segments comes with a few ramifications. All files except for the following are
copied to segments.
```
internal.auto.conf
postgresql.conf
pg_hba.conf
postmaster.opts
gp_dbid
gpssh.conf
gpperfmon
```

## What are the ramifications of copying MDD to segments to perform segment schema upgrade?
1. Existing MDD files are now on segments. Issues with this as the root cause
   has manifested in several ways.
    1. xids from coordinator ends up on segments, they must be edited to
       ensure row visibility on the segment is correct.
    1. pg_aoseg entries from the coordinator end up on the segments. It is
       assumed that segment relfilenode transfer will overwrite the
       coordinator's relfilenodes
    1. AO aux Free Space Maps (FSM) and Visibility Maps (VM) files from the
       coordinator end up on the segments. We need to ensure that the FSM and
       VM of AO aux tables from coordinator do not get used by segments. User
       tables are not so much of an issue because data is not stored on
       coordinator so these files should be empty or not exist.
1. pg_upgrade is fragmented because there are different code paths for
   coordinator and segment upgrades. pg_upgrade can be running in dispatch or
   segment mode.
1. Developers must keep in mind that pg_upgrade is run twice during execute.
   This has performance impacts because coordinator and segments cannot upgrade at
   the same time.
1. **Invalidated indexes**: bitmap, bpchar_pattern_ops, and indexes on AO tables
   are marked invalid on the new coordinator which are then copied to
   new segments. The relfiles for these indexes are excluded during relfilenode
   transfer. These indexes must be reindexed on the new cluster before they can
   be used, which is handled during gpupgrade finalize.
2. One good thing about this method is we know oids will the consistent across
   the cluster, which is needed for a GPDB cluster to function.


## list of issues/commits that are needed due to upgrading segments using copy MDD method
##### 1. Fix in get_rel_infos to resolve aoblkdir edge case
This fix is introduced in commit [466df4e26a](https://github.com/greenplum-db/gpdb/commit/466df4e26a).
```
	/*
	 * Resolve the edge case where an aoblkdir and its index exists, but the AO
	 * table it was created for no longer has any indexes. The aoblkdir is
	 * created the first time an index is placed on an AO table. If all indexes
	 * on the table are dropped, the aoblkdir is not removed even though it is
	 * unused. This is a known behavior. The edge case will result in an upgrade
	 * failure when relations between the old and new clusters are compared. The
	 * aoblkdirs and their indexes would exist on the old cluster, but not on
	 * the new cluster. Filtering them out here also prevents their relfilenodes
	 * from being transfered.
	 */
	PQclear(executeQueryOrDie(conn,
				"DELETE FROM info_rels WHERE reloid IN ("
				"SELECT c.oid "
				"FROM pg_class c "
				"JOIN pg_appendonly a ON c.oid IN (a.blkdirrelid, a.blkdiridxid) "
				"LEFT JOIN pg_index i ON i.indrelid = a.relid "
				"WHERE i.indexrelid IS NULL);"));
```

##### 2. Fix in transfer_relfile_segment to resolve _fsm and _vm edge case
This fix is introduced in commit
[466df4e26a](https://github.com/greenplum-db/gpdb/commit/466df4e26a).
```
	/*
	 * Because gpupgrade needs to copy MDD to segments in order to bootstrap
	 * upgrade segments, coordinator's relfilenodes, _fsm, _vm files will end up
	 * on segments. Normally this is ok since the files will end up being
	 * overwritten. However, there is an edge case where there can be data in a
	 * table on coordinator, but no data on the segment. Examples of such tables
	 * where this can occur are pg_ao(cs)seg tables. If this edge case happens,
	 * The new segment's table will end up with old segment's relfilenode and new
	 * coordinator's _fsm and _vm file. The _fsm and _vm files don't get
	 * overwritten because they aren't supposed to exist on the segment.
	 * Attempting to run VACUUM on this table after upgrade completes will
	 * result in a similar error below.
	 *
	 * ERROR:  could not read block 0 in file "base/16394/16393": read only 0 of 32768 bytes
	 *
	 * To prevent this failure, delete any _fsm or _vm files that should not exist
	 */
	if (type_suffix[0] == '\0')
	{
		unlink(new_file_fsm);
		unlink(new_file_vm);
	}
```

A better fix may be to exclude all *_fsm and *_vm files when rsycing from
coordinator to segments.

##### 3. pg_aoseg values from coordinator ends up on segments.
Before commit
[466df4e26a](https://github.com/greenplum-db/gpdb/commit/466df4e26a) every
pg_aoseg table was TRUNCATED before rebuilding it.

After commit
[466df4e26a](https://github.com/greenplum-db/gpdb/commit/466df4e26a), these
values are now transfered using relfilnodes. Segment relfilenode transfer will
overwrite the coordinator's relfilenodes. Maybe there are edge cases where
tuples exist on coordinator but not on segments?


##### 4. Reset system identifier
```
/*
 * Called for GPDB segments only -- since we have copied the master's
 * pg_control file, we need to assign a new system identifier to each segment.
 */
```

---

# Possible improvements discovered after making this README.

### 1. On segment pg_upgrade run, why is set_frozenxids and update_db_xids run one right after the other? They do the same thing. Fix datfrozenxid, relfrozenxid, and datminmxid. 

Why is this needed? How did we end up like this?
```
pg_upgrade on segments

├── set_frozenxids(false);*
│   ├── UPDATE pg_database SET datfrozenxid
│   ├── UPDATE pg_database SET datminmxid
│   ├── UPDATE pg_class SET relfrozenxid
│   └── UPDATE pg_class SET relminmxid
├── update_db_xids*
│   ├── UPDATE pg_database SET datfrozenxid, datminmxid
│   ├── UPDATE pg_class SET relfrozenxid
│   └── UPDATE pg_class SET relminmxid
```

##### Rough timeline of changes to end up here:
[5583ecdeba](https://github.com/greenplum-db/gpdb/commit/5583ecdeba)
**- pg_upgrade: freeze master data directory before copying to segments**<br>
This commit introduces freezing coordinator right before relfilenodes are
transferred. It is supposed to make the data on coordinator visible

[c0b4d5bcca](https://github.com/greenplum-db/gpdb/commit/c0b4d5bcca)
**- Fix xids on segments**<br>
Introduces the concept of running `VACUUM FREEZE` on segments to set the
following control file values on segments. 
```
Latest checkpoint's oldestXID
Latest checkpoint's oldestXID's DB
```

In order to get `VACUUM FREEZE` to run on the segments we must update the
Frozenxid and the minmxid to make the tuples that came from coordinator's
Relfilenode transfer visible. Then relfrozenxid, relminmxid are updated again
Relations using datfrozenxid which is the lowest available relfrozenxid to be
safe.

```
     if (is_greenplum_dispatcher_mode())
     {
         ...
     }
+    else
+    {
+        set_frozenxids(false);
+    }
+
+    freeze_all_databases();
+
+    if (!is_greenplum_dispatcher_mode())
+        update_segment_db_xids();
```

[194e78c18e](https://github.com/greenplum-db/gpdb/commit/194e78c18e)
**- pg_resetxlog:  add option to set oldest xid & use by pg_upgrade**<br>
[592c5c30ba](https://github.com/greenplum-db/gpdb/commit/592c5c30ba)
**Don't freeze before data transfer during segment upgrade**<br>

C0b4d5bcca7 introduced the notion of running a round of vacuum freeze on
segments in order to set the oldest xid in the new cluster explicitly
(since we can't rely on autovacuum in GPDB). Unfortunately, since this
Is done before the data link/copy step, unfrozen tuples in the new
Cluster referring to truncated CLOG segments will suffer from CLOG
Lookup failures.
```
     if (is_greenplum_dispatcher_mode())
     {
         ...
     }
     else
     {
         set_frozenxids(false);
     }

-    freeze_all_databases();
-
     if (!is_greenplum_dispatcher_mode())
         update_segment_db_xids();
```

The original reason for needing `set_frozen_xids(false)` is no longer needed.
We should be able to remove this an be ok.

### 2. Why does `vacuumdb --all --freeze` in prepare_new_cluster need to be called on segments?

This is part of original postgres code. It is supposed to freeze tables created
from init-db. I don't see a reason why this is still here. As ofc0b4d5bcca

[9cd8cd2630](https://github.com/greenplum-db/gpdb/commit/9cd8cd2630) -
pg_upgrade: freeze coordinator after relfilenode transfer

we also freeze coordinator after relfilenode transfer, which should cause the
`vacuumdb --all --freeze` in `prepare_new_cluster` to be a no-op on segments. 

We may be able to disable it to further simplify the workflow on segments.


### 3. I see a mixture of styles for skipping code. Do we want to consolidate styles?
**Style 1:** if statement wraps the functions. This style is likely easier to
read at a glance, but produces more diff that need to be handled when merging
from upstream.
```
if (!skip_checks())
    check_loadable_libraries();
```
**Style 2:** if statement immediately entering the function.
```
static void
check_new_cluster_is_empty(void)
{
    if (!is_greenplum_dispatcher_mode())
        return;
```

### 4. Investigate support to migrate bitmap indexes.
```
TODO: We are currently missing the support to migrate over bitmap indexes.
Hence, mark all bitmap indexes as invalid.
```

This commit broke bitmap indexes for GPDB6.
https://github.com/greenplum-db/gpdb/commit/c249ac7a36d9da3d25b6c419fbd07e2c9cfe954f

They were then fixed in this PR.
AO TID changes breaks bitmap indexes for GPDB6 AOCO tables. PR says they must
be remade after binary upgrade.
https://github.com/greenplum-db/gpdb/pull/8462
https://groups.google.com/a/greenplum.org/g/gpdb-dev/c/p8oTYMbHFaI/m/ZEDxFihlDgAJ

It looks like we must recreate bitmap indexes. We may be good to remove this comment.


### 5. get_db_and_rel_infos is called 4 times in coordinator.
Does this impact our performance in a noticeable way? Looking at it now two of
the calls are against empty new cluster.

Reason for each get_db_and_rel_infos call:
1. Gather old_cluster relations
1. check new cluster is empty
1. get database info (relations not restored yet)
1. get new cluster relations after they are restored

### 6. is a --binary-upgrade flag on pg_restore necessary?
The `--binary-upgrade` flag for pg_restore was a GPDB addition. See
https://github.com/pivotal/gp-gpdb-staging/commit/5844158d125bfc54714d65d6bb2bbf0bebf5fc4d

Lower priority thing to investigate.

### 7. `update_db_xid` and `set_frozenxid` look the same and do the same thing? Why?
These two functions look almost exactly identical and do the same things.
`set_frozenxid` is from postgres and `update_db_xid` is ours. It may be that
the team previously wanted to keep greenplum and postgres code separate, but
this looks unnecessary.

### 8. Disable segment compatibility checks.
Why do we run segment compatibility checks? It can potential cause upgrade
failure because it happens after coordinator upgrade is complete. There doesn't
seems to be a good reason to run the segment checks in our current gpupgrade
workflow other then causing unecessary changes to pg_upgrade. The point of
compatibility checks is to catch potential failures before upgrading a postgres
instance. By the time we run segment compatibility checks, segments are already
upgraded. Segments are upgraded by copying coordinator MDD to bootstrap
segments. And this is done right after coordinator upgrade is successful.
