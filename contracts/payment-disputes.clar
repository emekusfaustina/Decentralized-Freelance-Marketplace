;; Payment Dispute Resolution Contract
;; Mediates conflicts over compensation

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-DISPUTE-NOT-FOUND (err u401))
(define-constant ERR-INVALID-STATUS (err u402))
(define-constant ERR-INSUFFICIENT-STAKE (err u403))
(define-constant ERR-ALREADY-VOTED (err u404))
(define-constant ERR-VOTING-CLOSED (err u405))
(define-constant ERR-INVALID-EVIDENCE (err u406))

;; Data Variables
(define-data-var next-dispute-id uint u1)
(define-data-var arbitrator-stake-required uint u1000) ;; STX amount required to be arbitrator
(define-data-var dispute-fee uint u100) ;; Fee to initiate dispute

;; Data Maps
(define-map disputes
  { dispute-id: uint }
  {
    project-id: uint,
    milestone-id: (optional uint),
    complainant: principal,
    respondent: principal,
    amount-disputed: uint,
    reason: (string-ascii 500),
    status: uint, ;; 0: open, 1: evidence-phase, 2: voting, 3: resolved-complainant, 4: resolved-respondent, 5: cancelled
    created-at: uint,
    evidence-deadline: uint,
    voting-deadline: uint,
    resolved-at: (optional uint)
  }
)

(define-map dispute-evidence
  { dispute-id: uint, evidence-id: uint }
  {
    submitted-by: principal,
    evidence-type: uint, ;; 0: document, 1: communication, 2: deliverable, 3: other
    description: (string-ascii 300),
    file-hash: (string-ascii 64),
    submitted-at: uint
  }
)

(define-map arbitrators
  { arbitrator: principal }
  {
    stake-amount: uint,
    cases-handled: uint,
    success-rate: uint,
    active: bool,
    registered-at: uint
  }
)

(define-map dispute-arbitrators
  { dispute-id: uint, arbitrator: principal }
  {
    assigned-at: uint,
    vote: (optional uint), ;; 0: complainant, 1: respondent, 2: split
    vote-weight: uint,
    voted-at: (optional uint)
  }
)

(define-map dispute-votes
  { dispute-id: uint }
  {
    total-arbitrators: uint,
    votes-cast: uint,
    complainant-votes: uint,
    respondent-votes: uint,
    split-votes: uint,
    voting-complete: bool
  }
)

(define-map escrow-funds
  { dispute-id: uint }
  {
    amount: uint,
    deposited-by: principal,
    released: bool,
    release-to: (optional principal)
  }
)

;; Read-only functions
(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes { dispute-id: dispute-id })
)

(define-read-only (get-dispute-status (dispute-id uint))
  (match (map-get? disputes { dispute-id: dispute-id })
    dispute (get status dispute)
    u999
  )
)

(define-read-only (is-arbitrator (user principal))
  (match (map-get? arbitrators { arbitrator: user })
    arbitrator-data (get active arbitrator-data)
    false
  )
)

(define-read-only (get-arbitrator-info (arbitrator principal))
  (map-get? arbitrators { arbitrator: arbitrator })
)

(define-read-only (get-dispute-votes-summary (dispute-id uint))
  (map-get? dispute-votes { dispute-id: dispute-id })
)

;; Public functions
(define-public (create-dispute (project-id uint) (milestone-id (optional uint)) (respondent principal) (amount uint) (reason (string-ascii 500)))
  (let ((dispute-id (var-get next-dispute-id)))
    (asserts! (> amount u0) ERR-INVALID-STATUS)
    (asserts! (not (is-eq tx-sender respondent)) ERR-NOT-AUTHORIZED)

    ;; Create dispute record
    (map-set disputes
      { dispute-id: dispute-id }
      {
        project-id: project-id,
        milestone-id: milestone-id,
        complainant: tx-sender,
        respondent: respondent,
        amount-disputed: amount,
        reason: reason,
        status: u0,
        created-at: block-height,
        evidence-deadline: (+ block-height u1440), ;; ~1 day for evidence
        voting-deadline: (+ block-height u2880), ;; ~2 days total
        resolved-at: none
      }
    )

    ;; Initialize voting record
    (map-set dispute-votes
      { dispute-id: dispute-id }
      {
        total-arbitrators: u0,
        votes-cast: u0,
        complainant-votes: u0,
        respondent-votes: u0,
        split-votes: u0,
        voting-complete: false
      }
    )

    (var-set next-dispute-id (+ dispute-id u1))
    (ok dispute-id)
  )
)

(define-public (submit-evidence (dispute-id uint) (evidence-type uint) (description (string-ascii 300)) (file-hash (string-ascii 64)))
  (let (
    (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
    (evidence-count (get-evidence-count dispute-id))
  )
    (asserts! (or (is-eq tx-sender (get complainant dispute)) (is-eq tx-sender (get respondent dispute))) ERR-NOT-AUTHORIZED)
    (asserts! (<= (get status dispute) u1) ERR-INVALID-STATUS)
    (asserts! (< block-height (get evidence-deadline dispute)) ERR-VOTING-CLOSED)
    (asserts! (<= evidence-type u3) ERR-INVALID-EVIDENCE)

    (map-set dispute-evidence
      { dispute-id: dispute-id, evidence-id: (+ evidence-count u1) }
      {
        submitted-by: tx-sender,
        evidence-type: evidence-type,
        description: description,
        file-hash: file-hash,
        submitted-at: block-height
      }
    )

    ;; Update dispute status to evidence phase if not already
    (if (is-eq (get status dispute) u0)
      (map-set disputes
        { dispute-id: dispute-id }
        (merge dispute { status: u1 })
      )
      true
    )

    (ok true)
  )
)

(define-public (register-as-arbitrator (stake-amount uint))
  (begin
    (asserts! (>= stake-amount (var-get arbitrator-stake-required)) ERR-INSUFFICIENT-STAKE)

    (map-set arbitrators
      { arbitrator: tx-sender }
      {
        stake-amount: stake-amount,
        cases-handled: u0,
        success-rate: u100,
        active: true,
        registered-at: block-height
      }
    )
    (ok true)
  )
)

(define-public (assign-arbitrator (dispute-id uint) (arbitrator principal))
  (let ((dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-arbitrator arbitrator) ERR-NOT-AUTHORIZED)
    (asserts! (<= (get status dispute) u1) ERR-INVALID-STATUS)

    (map-set dispute-arbitrators
      { dispute-id: dispute-id, arbitrator: arbitrator }
      {
        assigned-at: block-height,
        vote: none,
        vote-weight: u1,
        voted-at: none
      }
    )

    ;; Update dispute status to voting phase
    (map-set disputes
      { dispute-id: dispute-id }
      (merge dispute { status: u2 })
    )

    ;; Update vote tracking
    (let ((current-votes (unwrap-panic (map-get? dispute-votes { dispute-id: dispute-id }))))
      (map-set dispute-votes
        { dispute-id: dispute-id }
        (merge current-votes { total-arbitrators: (+ (get total-arbitrators current-votes) u1) })
      )
    )

    (ok true)
  )
)

(define-public (cast-vote (dispute-id uint) (vote uint))
  (let (
    (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
    (arbitrator-assignment (unwrap! (map-get? dispute-arbitrators { dispute-id: dispute-id, arbitrator: tx-sender }) ERR-NOT-AUTHORIZED))
  )
    (asserts! (is-eq (get status dispute) u2) ERR-INVALID-STATUS)
    (asserts! (< block-height (get voting-deadline dispute)) ERR-VOTING-CLOSED)
    (asserts! (is-none (get vote arbitrator-assignment)) ERR-ALREADY-VOTED)
    (asserts! (<= vote u2) ERR-INVALID-STATUS)

    ;; Record the vote
    (map-set dispute-arbitrators
      { dispute-id: dispute-id, arbitrator: tx-sender }
      (merge arbitrator-assignment {
        vote: (some vote),
        voted-at: (some block-height)
      })
    )

    ;; Update vote counts
    (let ((current-votes (unwrap-panic (map-get? dispute-votes { dispute-id: dispute-id }))))
      (map-set dispute-votes
        { dispute-id: dispute-id }
        {
          total-arbitrators: (get total-arbitrators current-votes),
          votes-cast: (+ (get votes-cast current-votes) u1),
          complainant-votes: (if (is-eq vote u0) (+ (get complainant-votes current-votes) u1) (get complainant-votes current-votes)),
          respondent-votes: (if (is-eq vote u1) (+ (get respondent-votes current-votes) u1) (get respondent-votes current-votes)),
          split-votes: (if (is-eq vote u2) (+ (get split-votes current-votes) u1) (get split-votes current-votes)),
          voting-complete: (is-eq (+ (get votes-cast current-votes) u1) (get total-arbitrators current-votes))
        }
      )
    )

    (ok true)
  )
)

(define-public (resolve-dispute (dispute-id uint))
  (let (
    (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
    (vote-summary (unwrap! (map-get? dispute-votes { dispute-id: dispute-id }) ERR-DISPUTE-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status dispute) u2) ERR-INVALID-STATUS)
    (asserts! (or (get voting-complete vote-summary) (> block-height (get voting-deadline dispute))) ERR-VOTING-CLOSED)

    (let ((resolution (determine-resolution vote-summary)))
      (map-set disputes
        { dispute-id: dispute-id }
        (merge dispute {
          status: resolution,
          resolved-at: (some block-height)
        })
      )

      ;; Execute payment based on resolution
      (execute-dispute-resolution dispute-id resolution)
      (ok resolution)
    )
  )
)

;; Private functions
(define-private (get-evidence-count (dispute-id uint))
  ;; Simplified implementation - would count actual evidence entries
  u0
)

(define-private (determine-resolution (vote-summary { total-arbitrators: uint, votes-cast: uint, complainant-votes: uint, respondent-votes: uint, split-votes: uint, voting-complete: bool }))
  (let (
    (complainant-votes (get complainant-votes vote-summary))
    (respondent-votes (get respondent-votes vote-summary))
    (split-votes (get split-votes vote-summary))
  )
    (if (> complainant-votes respondent-votes)
      (if (> complainant-votes split-votes) u3 u4) ;; Complainant wins or split if tied
      (if (> respondent-votes split-votes) u4 u4) ;; Respondent wins or default to respondent
    )
  )
)

(define-private (execute-dispute-resolution (dispute-id uint) (resolution uint))
  ;; Implementation would handle actual fund transfers based on resolution
  ;; Simplified for this example
  true
)
