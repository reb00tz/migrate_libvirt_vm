# migrate_libvirt_vm
Script to migrate libvirt VMs via exporting and re-importing at destination. Has prerequisites as stated at top of script file.

# WARNING
By default, machine UUID is retained to ensure faithful migration/move, but if restoring onto different hardware, CPU flags may still change, breaking any OS activation reliant on hardware signatures.
Even when creating a clone using ```restore.sh --new-uuid```, the MAC addresses for network devices will be retained - ensure no MAC collisions are possible on any network legs VM is placed on/connected to.

# DISCLAIMER
Generated and logic-checked using AI - specifically Google AI mode, ChatGPT and own hosted Qwen 3.8 27B models.
