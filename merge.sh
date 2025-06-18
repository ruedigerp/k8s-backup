#!/bin/bash

#!/bin/bash

# Merge Script für verschiedene Branch-Kombinationen
# Usage: ./merge.sh <step>

STEP=$1

case $STEP in
  "dev-stage")
    echo "🚀 Merging dev -> stage"

    PR_OUTPUT=$(gh pr create \
      --base stage \
      --head dev \
      --title "Deploy dev to stage - $(date +%Y-%m-%d)" \
      --body "Deploy latest development changes to staging environment")
    
    # PR Number aus URL extrahieren (z.B. "https://github.com/user/repo/pull/123")
    PR_NUMBER=$(echo "$PR_OUTPUT" | grep -o '[0-9]\+$')
    
    gh pr merge $PR_NUMBER --merge --subject "Release stage" --auto

    ;;
    
  "stage-main")
    echo "🚀 Merging stage -> main"

    PR_OUTPUT=$(gh pr create \
      --base main \
      --head stage \
      --title "Deploy stage to main - $(date +%Y-%m-%d)" \
      --body "Deploy latest development changes to production environment")

    PR_NUMBER=$(echo "$PR_OUTPUT" | grep -o '[0-9]\+$')

    gh pr merge $PR_NUMBER --merge --subject "Release production" --auto

    ;;
    
  "back-merge")
    echo "🔄 Back-merging after production release"
    git fetch origin
    git checkout main
    git pull origin main
    LATEST_TAG=$(git tag | grep -v "-" | sort -V | tail -1)
    echo "Latest tag: $LATEST_TAG"
    
    # main -> stage
    PR_OUTPUT=$(gh pr create \
      --base stage \
      --head main \
      --title "Back-merge release $LATEST_TAG to stage" \
      --body "Sync stage with latest production release" )

    PR_NUMBER=$(echo "$PR_OUTPUT" | grep -o '[0-9]\+$')
    echo "PR Number: ${PR_NUMBER}"
    
    gh pr merge $PR_NUMBER --merge --subject "Back-merge release ${LATEST_TAG} [skip ci]" --auto

    # main -> dev  
    PR_OUTPUT=$(gh pr create \
      --base dev \
      --head main \
      --title "Back-merge release $LATEST_TAG to dev" \
      --body "Sync dev with latest production release")
    
    PR_NUMBER=$(echo "$PR_OUTPUT" | grep -o '[0-9]\+$')
    echo "PR Number: ${PR_NUMBER}"

    gh pr merge $PR_NUMBER --merge --subject "Back-merge release ${LATEST_TAG} [skip ci]" --auto
    ;;
    
  *)
    echo "❌ Unknown step: $STEP"
    echo ""
    echo "Usage: $0 <step>"
    echo ""
    echo "Available steps:"
    echo "  dev-stage   - Merge dev -> stage"
    echo "  stage-main  - Merge stage -> main"  
    echo "  back-merge  - Back-merge main -> stage & dev after release"
    echo ""
    echo "Examples:"
    echo "  $0 dev-stage"
    echo "  $0 stage-main"
    echo "  $0 back-merge"
    exit 1
    ;;
esac

echo "✅ Done!"



