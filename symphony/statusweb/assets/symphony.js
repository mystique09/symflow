(() => {
  const pollIntervalMs = 2000
  let refreshTimer = 0
  let refreshing = false

  function liveRegion(name, root = document) {
    return root.querySelector(`[data-live-region="${name}"]`)
  }

  function replaceRegion(current, next) {
    if (!current || !next || current.innerHTML === next.innerHTML) {
      return false
    }
    current.replaceChildren(...Array.from(next.childNodes, (node) => node.cloneNode(true)))
    return true
  }

  function queueSummary(board) {
    return Array.from(board.querySelectorAll('.board-column-header .tag'))
      .map((tag) => tag.getAttribute('aria-label') || tag.textContent.trim())
      .join(', ')
  }

  function updateQueues(nextDocument) {
    const current = liveRegion('queues')
    const next = liveRegion('queues', nextDocument)
    if (!current || !next || current.innerHTML === next.innerHTML) {
      return
    }
    if (current.contains(document.activeElement)) {
      return
    }

    const previousSummary = queueSummary(current)
    const nextSummary = queueSummary(next)
    const scrollLeft = current.scrollLeft
    current.setAttribute('aria-busy', 'true')
    replaceRegion(current, next)
    current.scrollLeft = Math.min(scrollLeft, current.scrollWidth - current.clientWidth)
    current.removeAttribute('aria-busy')

    if (previousSummary !== nextSummary) {
      const status = document.querySelector('[data-live-status]')
      if (status) {
        status.textContent = `Queue update: ${nextSummary}.`
      }
    }
  }

  async function refresh() {
    if (refreshing) {
      return
    }
    refreshing = true
    try {
      if (document.hidden) {
        return
      }
      const response = await fetch(window.location.href, {
        cache: 'no-store',
        credentials: 'same-origin',
        headers: {
          Accept: 'text/html',
        },
      })
      if (!response.ok) {
        return
      }
      const nextDocument = new DOMParser().parseFromString(await response.text(), 'text/html')
      replaceRegion(liveRegion('metadata'), liveRegion('metadata', nextDocument))
      updateQueues(nextDocument)
    } catch {
      // The next poll retries transient local-server or network failures.
    } finally {
      refreshing = false
      refreshTimer = window.setTimeout(refresh, pollIntervalMs)
    }
  }

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
      window.clearTimeout(refreshTimer)
      refreshTimer = window.setTimeout(refresh, 0)
    }
  })

  refreshTimer = window.setTimeout(refresh, pollIntervalMs)
})()
