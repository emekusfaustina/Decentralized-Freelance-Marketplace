;; Project Milestone Tracking Contract
;; Monitors work progress and deliverable completion

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-PROJECT-NOT-FOUND (err u201))
(define-constant ERR-MILESTONE-NOT-FOUND (err u202))
(define-constant ERR-INVALID-STATUS (err u203))
(define-constant ERR-DEADLINE-PASSED (err u204))
(define-constant ERR-ALREADY-COMPLETED (err u205))

;; Data Variables
(define-data-var next-project-id uint u1)
(define-data-var next-milestone-id uint u1)

;; Data Maps
(define-map projects
  { project-id: uint }
  {
    title: (string-ascii 100),
    description: (string-ascii 500),
    client: principal,
    freelancer: principal,
    budget: uint,
    deadline: uint,
    status: uint, ;; 0: created, 1: active, 2: completed, 3: cancelled
    created-at: uint
  }
)

(define-map milestones
  { milestone-id: uint }
  {
    project-id: uint,
    title: (string-ascii 100),
    description: (string-ascii 300),
    payment-amount: uint,
    deadline: uint,
    status: uint, ;; 0: pending, 1: in-progress, 2: submitted, 3: approved, 4: rejected
    created-at: uint,
    completed-at: (optional uint)
  }
)

(define-map deliverables
  { milestone-id: uint, deliverable-id: uint }
  {
    title: (string-ascii 100),
    description: (string-ascii 300),
    file-hash: (string-ascii 64),
    submitted-at: uint,
    approved: bool
  }
)

(define-map project-participants
  { project-id: uint, user: principal }
  { role: uint } ;; 0: client, 1: freelancer
)

;; Read-only functions
(define-read-only (get-project (project-id uint))
  (map-get? projects { project-id: project-id })
)

(define-read-only (get-milestone (milestone-id uint))
  (map-get? milestones { milestone-id: milestone-id })
)

(define-read-only (get-project-status (project-id uint))
  (match (map-get? projects { project-id: project-id })
    project (get status project)
    u999 ;; Not found indicator
  )
)

(define-read-only (is-project-participant (project-id uint) (user principal))
  (is-some (map-get? project-participants { project-id: project-id, user: user }))
)

(define-read-only (get-milestone-progress (project-id uint))
  (let (
    (total-milestones (count-project-milestones project-id))
    (completed-milestones (count-completed-milestones project-id))
  )
    (if (> total-milestones u0)
      (/ (* completed-milestones u100) total-milestones)
      u0
    )
  )
)

;; Public functions
(define-public (create-project (title (string-ascii 100)) (description (string-ascii 500)) (freelancer principal) (budget uint) (deadline uint))
  (let ((project-id (var-get next-project-id)))
    (asserts! (> deadline block-height) ERR-DEADLINE-PASSED)
    (asserts! (> budget u0) ERR-INVALID-STATUS)

    (map-set projects
      { project-id: project-id }
      {
        title: title,
        description: description,
        client: tx-sender,
        freelancer: freelancer,
        budget: budget,
        deadline: deadline,
        status: u0,
        created-at: block-height
      }
    )

    (map-set project-participants { project-id: project-id, user: tx-sender } { role: u0 })
    (map-set project-participants { project-id: project-id, user: freelancer } { role: u1 })

    (var-set next-project-id (+ project-id u1))
    (ok project-id)
  )
)

(define-public (create-milestone (project-id uint) (title (string-ascii 100)) (description (string-ascii 300)) (payment-amount uint) (deadline uint))
  (let (
    (milestone-id (var-get next-milestone-id))
    (project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
  )
    (asserts! (is-project-participant project-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> deadline block-height) ERR-DEADLINE-PASSED)
    (asserts! (<= deadline (get deadline project)) ERR-DEADLINE-PASSED)

    (map-set milestones
      { milestone-id: milestone-id }
      {
        project-id: project-id,
        title: title,
        description: description,
        payment-amount: payment-amount,
        deadline: deadline,
        status: u0,
        created-at: block-height,
        completed-at: none
      }
    )

    (var-set next-milestone-id (+ milestone-id u1))
    (ok milestone-id)
  )
)

(define-public (start-milestone (milestone-id uint))
  (let ((milestone (unwrap! (map-get? milestones { milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND)))
    (asserts! (is-project-participant (get project-id milestone) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status milestone) u0) ERR-INVALID-STATUS)

    (map-set milestones
      { milestone-id: milestone-id }
      (merge milestone { status: u1 })
    )
    (ok true)
  )
)

(define-public (submit-milestone (milestone-id uint) (deliverable-title (string-ascii 100)) (deliverable-desc (string-ascii 300)) (file-hash (string-ascii 64)))
  (let ((milestone (unwrap! (map-get? milestones { milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND)))
    (asserts! (is-project-participant (get project-id milestone) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status milestone) u1) ERR-INVALID-STATUS)

    (map-set deliverables
      { milestone-id: milestone-id, deliverable-id: u1 }
      {
        title: deliverable-title,
        description: deliverable-desc,
        file-hash: file-hash,
        submitted-at: block-height,
        approved: false
      }
    )

    (map-set milestones
      { milestone-id: milestone-id }
      (merge milestone { status: u2 })
    )
    (ok true)
  )
)

(define-public (approve-milestone (milestone-id uint))
  (let (
    (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND))
    (project (unwrap! (map-get? projects { project-id: (get project-id milestone) }) ERR-PROJECT-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status milestone) u2) ERR-INVALID-STATUS)

    (map-set milestones
      { milestone-id: milestone-id }
      (merge milestone {
        status: u3,
        completed-at: (some block-height)
      })
    )

    (map-set deliverables
      { milestone-id: milestone-id, deliverable-id: u1 }
      (merge
        (unwrap-panic (map-get? deliverables { milestone-id: milestone-id, deliverable-id: u1 }))
        { approved: true }
      )
    )

    (ok true)
  )
)

(define-public (reject-milestone (milestone-id uint))
  (let (
    (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND))
    (project (unwrap! (map-get? projects { project-id: (get project-id milestone) }) ERR-PROJECT-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status milestone) u2) ERR-INVALID-STATUS)

    (map-set milestones
      { milestone-id: milestone-id }
      (merge milestone { status: u4 })
    )
    (ok true)
  )
)

(define-public (complete-project (project-id uint))
  (let ((project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    (asserts! (< (get status project) u2) ERR-ALREADY-COMPLETED)

    (map-set projects
      { project-id: project-id }
      (merge project { status: u2 })
    )
    (ok true)
  )
)

;; Private functions
(define-private (count-project-milestones (project-id uint))
  ;; Simplified implementation - in practice would iterate through all milestones
  u1
)

(define-private (count-completed-milestones (project-id uint))
  ;; Simplified implementation - in practice would count approved milestones
  u0
)
