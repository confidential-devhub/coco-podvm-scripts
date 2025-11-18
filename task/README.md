# build-dm-verity-image Task — README

This README describes the Tekton Task defined in `build-dm-verity-image.yaml` and
how it fits into the repository pipeline for building a DM‑Verity PodVM image.

## Purpose and constraints

The `build-dm-verity-image` Task automates building a disk image (QCOW2) with
DM‑Verity support and packaging it as a container image, as part of our Konflux CI.
The task runs on a remote build host (accessed via SSH) and uses Podman/Buildah
on that host to produce the final image and push it to a remote registry.

This task was built because the regular build tasks offered in Konflux did not
provide the capabilities (mainly: privileges) to run some of the steps neededd
for the build.

This task needs to be built and published to `quay.io/konflux-ci/ose-osc-tenant/build-dm-verity-image-task`
so that it can be trusted for releasing images to Red Hat repositories. In order
to comply with security requirements, the task must be self-contained (no reference
to external scripts).

For this reason, this task does not reference the scripts from this repository,
but embeds them (or part of them) into the task itself.
i.e: Any change to the scripts requires a similar change to be done to the task.

## Build steps

At a high level, the task is doing the following:

1. Download a RHEL installation ISO (authenticated with a Red Hat offline token)
   and verify checksum.
2. Copy sources and required files to the remote SSH build host and run a script
   remotely to build the QCOW image.
3. Generate a minimal SBOM for the published image.

Additional steps and code exist in the task to share context with the other tasks
in our CI (running before or after it). We won't detail them in this document.

### step "download-rhel-image"

This step retrieves the ISO image that will be used to create the base VM image
that will be customized for our purpose.

We need a dedicated token to authenticate to the repository. This is why we
can't just use the existing "prefetch-dependencies" task from Konflux.

This step requires the following parameters:

- REDHAT_OFFLINE_TOKEN_SECRET: offline token used to authenticate
- REDHAT_IMAGE_CHECKSUM: used to verify the integrity of the downloaded file

This step will pull the image in an attached volume under /var/workdir, which
will be shared with the other steps of the task.

### step "build"

This is the main part of the task.
When the task is executed, an ephemeral VM is provided that we can use to run our
build steps. The VM configuration can be found in the [infra-deployments repository](https://github.com/redhat-appstudio/infra-deployments/blob/main/components/multi-platform-controller/production/stone-prd-rh01/host-values.yaml).
The task uses SSH to copy files and execute commands on that VM.

This step will create various scripts, copy them to the VM, and then execute
them to build our image.

- **script-build.sh**

  This is the main script, that will orchestrate the build, running the other
  scripts as needed. It is executed as the main entry point, using ssh at the
  end of the task.
  
  It is using podman to do the following:

  - build a container using the file `konflux/Dockefile`
    This Dockerfile is a very simple init container, where we copy the
    podvm-payload binaries, and install some needed pacakges, so that the rest
    of the build can be performed within it.
  - run this container in the background
  - use `podman exec` on the running container to perform actual build steps
    - run virt-install to create the base image using the downloaded ISO
    - run "script-verify.sh"
    - run "podvm-measure.sh"
    - run "script-push.sh"

- **script-verity.sh**

  This script will copy some files to the image:

  - binaries from the podvm payload image
  - files from this repository's `konflux/podvm-root` folder

  It does so using `virt-customize`, and a secondary script `script-podvm-maker.sh`.

  Then it resizes the disk, apply dm-verity, and create uki addon.

- **podvm-measure.sh**

  This script runs the VM to collect measurement data, writing them to a file in
  the task's output directory (`measurements.json`).

- **script-push.sh**

  Uses Buildah to package the QCOW2 file into a container image and pushes it to
  the registry.

### step "sbom-generate"

This step is required for Konflux CI, but we are currently doing a very simple
(empty) SBOM. We need to improve this.

## Build and publish the task

In order to be used, this task needs to be built and published to the quay.io
repository.

The build pipelines for this task are defined in the `.tekton/build-dm-verity-image-task-*.yaml` files.

When the pull request that changes the task is merged, a build is triggered, and
the resulting image is pushed to the `quay.io/konflux_ci/` repository.

Then a PR is automatically created to modify the task's reference in the actual
dm-verity pipeline (see `.tekton/build-piepline.yaml`). Merging this will run
a new build of dm-verity, with the modified task.

Note that there can be a delay between the build of the task and its availability
on quay. More often than not, the nudge pull request that update the task will
fail to build because of that, with an error saying it can't find the task.
We usually need to run `/retest` on it, to run the build properly.

## Run the task locally without publishing

It is possible to use the task locally, without building/publishing it.
Doing so, we can build osc-dm-verity-image with a custom task (typically: for
testing some modification of the task itself).

The resulting image will not be releasable, because the task that builds it is
not trusted. This method should be used only for development and troubleshooting.

To build dm-verity with a local task, you can do the following:

- copy the task from `task/build-dm-verity-image/0.1/` to `.tekton/`
- reference it in `.tekton/build-pipeline.yaml` in place of the quay.io reference

Here is [an example of this change](https://github.com/confidential-devhub/coco-podvm-scripts/pull/103/commits/bb4eac66032be90c9f97f002453d1368bc792918).
