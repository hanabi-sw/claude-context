# Which kernel does an AMI (or a host) run?

AWS, any Amazon Linux AMI. Read when a CVE/ALAS asks "is this AMI or host patched?" or a plan picks a
target AMI for a kernel fix.
Verified against account 546532984119 / eu-central-1 with the low-priv role on 2026-11-03.

The kernel version is not an AMI attribute. Prove it in this order: running host (direct), then the
AMI's release notes (indirect, no host needed). All commands below are read-only.

## 1. A host already runs the AMI: read its boot console

```bash
export AWS_REGION=eu-central-1 AWS_PAGER=""
AMI=ami-0d6f244030786337b
aws ec2 describe-instances --filters Name=image-id,Values=$AMI Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text
aws ec2 get-console-output --instance-id <i-…> --latest --query Output --output text | grep -m1 -E '^Kernel |Linux version'
# Kernel 6.1.189-236.400.amzn2023.x86_64 on an x86_64 (-)
```

- Shows the kernel the host **booted**. `dnf`/`yum` may have installed a newer one that is not running yet.
- `--latest` needs a Nitro instance (t3, m6a, c5…). Without it you get a buffered copy, which can be empty.
- Not usable: SSM inventory (`AWS:Application`) has no kernel entry on these hosts.
- `uname -r` through `aws ssm send-command` also works, but `SendCommand` is a write. Hand it to the user.
  For ECS ASGs: `~/code/ai-plans/cve-2026-98432-kernel-patching/ecs-ami-patch.sh kernel <asg>`.

## 2. No host yet: AMI → base image → AL2023 release notes

```bash
aws ec2 describe-images --image-ids $AMI --query 'Images[0].[Name,ImageOwnerAlias,CreationDate]' --output text
# owner alias must be `amazon`
# ECS-optimised AMIs: the base image, by AMI ID (old AMIs still resolve)
aws ssm get-parameter --name /aws/service/ecs/optimized-ami/amazon-linux-2023/$AMI \
  --query Parameter.Value --output text   # → "source_image_name": "al2023-ami-minimal-2023.12.20261102.0-kernel-6.1-x86_64"
```

- The AL2023 version is the `2023.x.YYYYMMDD` in the base image name. For a plain AL2023 AMI it is
  in the AMI's own name (`al2023-ami-2023.12.20261102.0-kernel-6.1-x86_64`).
- Release notes: `https://docs.aws.amazon.com/linux/al2023/release-notes/relnotes-<version>.html`
  (e.g. `relnotes-2023.12.20261102.html`). Look under **Minimal Kernel 6.1 AMI** / **Default Kernel 6.1 AMI**
  for `kernel-1:6.1.…`. The notes list only packages that changed in that release. If the kernel is
  missing, it is unchanged: walk back to earlier releases.
- ECS AMI release notes (`gh release view <YYYYMMDD> --repo aws/amazon-ecs-ami`) name the base image
  but not the kernel.
- The ECS "recommended" parameter: `/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended`.

## 3. Compare against the advisory

`https://alas.aws.amazon.com/AL2023/ALAS2023-<id>.html` names the fixed package
(e.g. `kernel-6.1.189-236.400.amzn2023.x86_64`). Patched = booted kernel ≥ that, compared with `sort -V`
on the part before `.amzn2023`.

Quirk: base image dates can be later than the ECS AMI's `CreationDate` (`20261102` base for an AMI
created 2026-10-31). Treat the release notes plus a live `Kernel` line as the proof, not the dates.
