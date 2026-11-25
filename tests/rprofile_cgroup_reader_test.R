#!/usr/bin/env Rscript
# tests/rprofile_cgroup_reader_test.R — regression for the cgroup/RAM banner
# values (Rprofile v12.11-fix4).
#
# Bug (calc01, 2026-11-25): the banner said "slice limit: none" and status()
# "src: not detected — check systemd slice config", and showed "VM 400GB" from
# a constant rendered at deploy time. The reader looked up
# user.slice/user-<uid>.slice by UID, but an RStudio rsession runs in
# /system.slice/rstudio-server.service. The reader must follow
# /proc/self/cgroup and the total RAM must come from MemTotal.
#
# Runs the exact function code from fragment 20 against fake cgroup trees.

frag <- readLines("templates/Rprofile_site.d/20_cgroup_reader.R.template", warn = FALSE)
extract <- function(from_re, to_re) {
  s <- grep(from_re, frag)[1]
  e <- grep(to_re, frag)
  e <- e[e > s][1] - 1L
  stopifnot(is.finite(s), is.finite(e), e > s)
  paste(frag[s:e], collapse = "\n")
}
reader_code <- extract("^  \\.biome_cgroup_read_limits <- function", "Hardware Topology")
total_code  <- extract("^  \\.biome_total_ram_gb <- function", "shared_env\\$total_ram_gb <-")

ENABLE_CGROUP_AWARE <- TRUE
VM_RAM_GB <- 450L
MY_UID <- 1000L
logs <- character()
sys_log <- function(tag, lvl, msg) logs <<- c(logs, msg)
eval(parse(text = reader_code))
eval(parse(text = total_code))

n_fail <- 0L
check <- function(id, ok) {
  cat(sprintf("%s %s\n", if (isTRUE(ok)) "PASS" else "FAIL", id))
  if (!isTRUE(ok)) n_fail <<- n_fail + 1L
}

GiB <- 1024^3
mk_tree <- function(self_path, files) {
  root <- tempfile("cg-")
  dir.create(root)
  for (rel in names(files)) {
    f <- file.path(root, "sys", rel)
    dir.create(dirname(f), recursive = TRUE, showWarnings = FALSE)
    writeLines(files[[rel]], f)
  }
  dir.create(file.path(root, "sys"), showWarnings = FALSE)
  pc <- file.path(root, "proc_cgroup")
  writeLines(if (is.null(self_path)) character(0) else paste0("0::", self_path), pc)
  list(pc = pc, cg = file.path(root, "sys"))
}
n_warn <- 0L
rd <- function(t, uid = 1000L) withCallingHandlers(
  .biome_cgroup_read_limits(uid, proc_cgroup = t$pc, cg_root = t$cg),
  warning = function(w) { n_warn <<- n_warn + 1L; invokeRestart("muffleWarning") })

# C1 calc01 case: rsession in rstudio-server.service, no memory.max anywhere,
#    while user-1000.slice HAS 400G. The old code reported the user slice (or
#    "not detected"); the session is not in it, so the answer is "no limit".
t <- mk_tree("/system.slice/rstudio-server.service", list(
  "system.slice/rstudio-server.service/memory.max" = "max",
  "system.slice/rstudio-server.service/memory.high" = "max",
  "system.slice/rstudio-server.service/cpu.max" = "max 100000",
  "system.slice/memory.max" = "max",
  "user.slice/user-1000.slice/memory.max" = as.character(400 * GiB)))
r <- rd(t)
check("C1 path is the session cgroup", identical(r$cgroup_path, "/system.slice/rstudio-server.service"))
check("C1 no memory limit (user slice ignored)", !is.finite(r$ram_gb))
check("C1 source says unlimited, not 'none'", identical(r$source, "cgroupv2-unlimited"))
check("C1 cpus unlimited", !is.finite(r$cpus))

# C2 SSH/console login: session scope under the user slice inherits 400G/300G.
t <- mk_tree("/user.slice/user-1000.slice/session-3.scope", list(
  "user.slice/user-1000.slice/session-3.scope/memory.max" = "max",
  "user.slice/user-1000.slice/memory.max" = as.character(400 * GiB),
  "user.slice/user-1000.slice/memory.high" = as.character(300 * GiB),
  "user.slice/memory.max" = "max"))
r <- rd(t)
check("C2 ram 400", isTRUE(all.equal(r$ram_gb, 400)))
check("C2 high 300", isTRUE(all.equal(r$ram_high_gb, 300)))
check("C2 source user slice", identical(r$source, "cgroupv2-user-slice"))

# C3 tightest limit wins along the path; CPU quota read from an ancestor.
t <- mk_tree("/system.slice/rstudio-server.service", list(
  "system.slice/rstudio-server.service/memory.max" = as.character(200 * GiB),
  "system.slice/memory.max" = as.character(300 * GiB),
  "system.slice/cpu.max" = "800000 100000"))
r <- rd(t)
check("C3 ram is the tightest (200)", isTRUE(all.equal(r$ram_gb, 200)))
check("C3 source session cgroup", identical(r$source, "cgroupv2-self"))
check("C3 cpus 8 from ancestor", isTRUE(all.equal(r$cpus, 8)))

# C4 root cgroup ("0::/"): nothing to walk, no limit, no error.
t <- mk_tree("/", list())
r <- rd(t)
check("C4 root path", identical(r$cgroup_path, "/"))
check("C4 root unlimited", !is.finite(r$ram_gb) && identical(r$source, "cgroupv2-unlimited"))

# C5 garbage in memory.max does not throw and is ignored.
t <- mk_tree("/system.slice/x.service", list(
  "system.slice/x.service/memory.max" = "garbage",
  "system.slice/x.service/cpu.max" = "nonsense"))
r <- tryCatch(rd(t), error = function(e) NULL)
check("C5 no error on bad values", !is.null(r) && !is.finite(r$ram_gb) && !is.finite(r$cpus))

# C6 disabled flag: nothing read.
ENABLE_CGROUP_AWARE <- FALSE
r <- rd(mk_tree("/system.slice/rstudio-server.service", list()))
check("C6 disabled returns none", identical(r$source, "none"))
ENABLE_CGROUP_AWARE <- TRUE

# W1 nothing may print at profile load: missing controller files are normal.
check("W1 reader raised no warnings", n_warn == 0L)
# P1 no "0::" line (cgroup v1 host): the v2 walk is skipped (legacy fallback).
t <- mk_tree(NULL, list())
writeLines("1:memory:/user.slice", t$pc)
r <- rd(t)
check("P1 v1 host: no v2 cgroup path", is.na(r$cgroup_path))

# T1 total RAM measured from MemTotal (427819008 kB = 408 GiB), not VM_RAM_GB.
mi <- tempfile("meminfo-")
writeLines(c("MemTotal:       427819008 kB", "MemFree:        1000 kB",
             "MemAvailable:   378535936 kB"), mi)
check("T1 MemTotal 408 GiB", isTRUE(all.equal(.biome_total_ram_gb(mi), 427819008 / 1024 / 1024)))
check("T1 not the constant", abs(.biome_total_ram_gb(mi) - VM_RAM_GB) > 1)
# T2 unreadable meminfo: falls back to the configured constant.
w2 <- 0L
v2 <- withCallingHandlers(.biome_total_ram_gb(tempfile("nope-")),
  warning = function(w) { w2 <<- w2 + 1L; invokeRestart("muffleWarning") })
check("T2 fallback VM_RAM_GB, no warning", identical(v2, 450) && w2 == 0L)

# F1 banner/status code uses the new fields (guards against a partial revert).
f70 <- paste(readLines("templates/Rprofile_site.d/70_persistent_tools.R.template", warn = FALSE), collapse = "\n")
check("F1 banner no longer prints the VM_RAM_GB constant as 'VM %dGB'", !grepl("VM %dGB", f70, fixed = TRUE))
check("F1 status prints the session cgroup", grepl("cgroup_path", f70, fixed = TRUE))
check("F1 no 'not detected' advice for a readable cgroup", !grepl("not detected — check systemd slice config", f70, fixed = TRUE))

if (n_fail > 0L) {
  cat(sprintf("\n%d check(s) failed\n", n_fail))
  quit(status = 1L)
}
cat("\nall cgroup reader checks passed\n")
