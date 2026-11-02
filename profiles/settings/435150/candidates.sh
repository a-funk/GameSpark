# shellcheck shell=bash disable=SC2034  # sourced by profiles/settings/435150/apply.sh and bench/games/dos2.sh
# Divinity: Original Sin 2 candidates: MapKey=Value pairs for graphicSettings.lsx (apply.sh describes A and B).
DOS2_A=(ScreenWidth=3840 ScreenHeight=2160)
DOS2_B=("${DOS2_A[@]}" SSAOEnabled=0 GodRaysEnabled=0)
