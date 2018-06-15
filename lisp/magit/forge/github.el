;;; magit/forge/github.el ---                     -*- lexical-binding: t -*-

;; Copyright (C) 2010-2018  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Code:

(require 'ghub)
(require 'magit/forge)
(require 'magit/forge/issue)
(require 'magit/forge/pullreq)

;;; Variables

(defvar magit-github-token-scopes '(repo)
  "The Github API scopes needed by Magit.

`repo' is the only required scope.  Without this scope none of
Magit's features that use the API work.  Instead of this scope
you could use `public_repo' if you are only interested in public
repositories.

`repo' Grants read/write access to code, commit statuses,
  invitations, collaborators, adding team memberships, and
  deployment statuses for public and private repositories
  and organizations.

`public_repo' Grants read/write access to code, commit statuses,
  collaborators, and deployment statuses for public repositories
  and organizations. Also required for starring public
  repositories.")

;;; Projects

(defclass magit-github-project (magit-forge-project)
  ((issue-url-format          :initform "https://%h/%o/%n/issues/%i")
   (pullreq-url-format        :initform "https://%h/%o/%n/pull/%i")
   ))

(cl-defmethod magit-forge--object-id
  ((_class (subclass magit-github-project)) forge host owner name)
  "Return the id of the specified project.
This method has to make an API request."
  (let-alist (ghub-graphql "\
query ($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    id }}" `((owner . ,owner)
             (name  . ,name))
    :host host :auth 'magit)
    (format "%s:%s" forge .data.repository.id)))

;;; Issues

(cl-defmethod magit-forge--pull-issues ((prj magit-github-project))
  (emacsql-with-transaction (magit-db)
    (mapc #'closql-delete (oref prj issues))
    (dolist (i (magit-forge--fetch-issues prj))
      (let-alist i
        (let* ((issue-id (magit-forge--object-id prj .number))
               (issue
                (magit-forge-issue
                 :id           issue-id
                 :project      (oref prj id)
                 :number       .number
                 :state        (intern (downcase .state))
                 :author       .author.login
                 :title        .title
                 :created      .createdAt
                 :updated      .updatedAt
                 :closed       .closedAt
                 :locked-p     .locked
                 :milestone    .milestone.id
                 :body         (replace-regexp-in-string "\n" "\n" .body)
                 )))
          (closql-insert (magit-db) issue)
          (dolist (c .posts)
            (let-alist c
              (let ((post
                     (magit-forge-issue-post
                      :id           (format "%s:%s" issue-id .databaseId)
                      :issue        issue-id
                      :number       .databaseId
                      :author       .author.login
                      :created      .createdAt
                      :updated      .updatedAt
                      :body         (replace-regexp-in-string "\n" "\n" .body)
                      )))
                (closql-insert (magit-db) post)
                ))))))))

(defconst magit-github--fetch-issues "\
query ($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    issues(first:100, states:[OPEN]) {
      totalCount
      pageInfo {
        startCursor
        endCursor
        hasNextPage }
      edges {
        cursor
        node {
          number
          state
          author { login }
          title
          createdAt
          updatedAt
          closedAt
          locked
          milestone { id }
          body
          comments(first:100) {
            totalCount
            pageInfo {
              startCursor
              endCursor
              hasNextPage }
            edges {
              cursor
              node {
                id
                databaseId
                author { login }
                createdAt
                updatedAt
                body }}}
        }}}}}")

(cl-defmethod magit-forge--fetch-issues ((prj magit-github-project))
  (mapcar
   (lambda (issue-edge)
     (let ((issue-node (cdr (assq 'node issue-edge))))
       (let-alist issue-node
         (setf (alist-get 'comments issue-node)
               (mapcar (lambda (comment-edge)
                         (let ((comment-node (cdr (assq 'node comment-edge))))
                           ;; (let-alist comment-node
                           ;;   (setf (alist-get 'author comment-node)
                           ;;         .author.login))
                           comment-node))
                       .comments.edges)))
       issue-node))
   (let-alist (magit--ghub-graphql prj magit-github--fetch-issues
                                   `((owner . ,(oref prj owner))
                                     (name  . ,(oref prj name))))
     .data.repository.issues.edges)))

;;; Pullreqs

(cl-defmethod magit-forge--pull-pullreqs ((prj magit-github-project))
  (emacsql-with-transaction (magit-db)
    (mapc #'closql-delete (oref prj pullreqs))
    (dolist (p (magit-forge--fetch-pullreqs prj))
      (let-alist p
        (let* ((pullreq-id (magit-forge--object-id prj .number))
               (pullreq
                (magit-forge-pullreq
                 :id           pullreq-id
                 :project      (oref prj id)
                 :number       .number
                 :state        (intern (downcase .state))
                 :author       .author.login
                 :title        .title
                 :created      .createdAt
                 :updated      .updatedAt
                 :closed       .closedAt
                 :merged       .mergedAt
                 :locked-p     .locked
                 :editable-p   .maintainerCanModify
                 :cross-repo-p .isCrossRepository
                 :base-ref     .baseRef.name
                 :base-repo    .baseRef.repository.nameWithOwner
                 :head-ref     .headRef.name
                 :head-user    .headRef.repository.owner.login
                 :head-repo    .headRef.repository.nameWithOwner
                 :milestone    .milestone.id
                 :body         (replace-regexp-in-string "\n" "\n" .body)
                 )))
          (closql-insert (magit-db) pullreq)
          (dolist (p .comments)
            (let-alist p
              (let ((post
                     (magit-forge-pullreq-post
                      :id           (format "%s:%s" pullreq-id .databaseId)
                      :pullreq      pullreq-id
                      :number       .databaseId
                      :author       .author.login
                      :created      .createdAt
                      :updated      .updatedAt
                      :body         (replace-regexp-in-string "\n" "\n" .body)
                      )))
                (closql-insert (magit-db) post)
                ))))))))

(defconst magit-github--fetch-pullreqs "\
query ($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    pullRequests(first:100, states:[OPEN]) {
      totalCount
      pageInfo {
        startCursor
        endCursor
        hasNextPage }
      edges {
        cursor
        node {
          number
          state
          author { login }
          title
          createdAt
          updatedAt
          closedAt
          mergedAt
          locked
          maintainerCanModify
          isCrossRepository
          milestone { id }
          body
          baseRef {
            name
            repository {
              nameWithOwner }}
          headRef {
            name
            repository {
              owner {
                login }
              nameWithOwner }}
          comments(first:100) {
            totalCount
            pageInfo {
              startCursor
              endCursor
              hasNextPage }
            edges {
              cursor
              node {
                databaseId
                author { login }
                createdAt
                updatedAt
                body }}}
          }}}}}")

(cl-defmethod magit-forge--fetch-pullreqs ((prj magit-github-project))
  (mapcar
   (lambda (pullreq-edge)
     (let ((pullreq-node (cdr (assq 'node pullreq-edge))))
       (let-alist pullreq-node
         (setf (alist-get 'comments pullreq-node)
               (mapcar (lambda (comment-edge)
                         (let ((comment-node (cdr (assq 'node comment-edge))))
                           ;; (let-alist comment-node
                           ;;   (setf (alist-get 'author comment-node)
                           ;;         .author.login))
                           comment-node))
                       .comments.edges)))
       pullreq-node))
   (let-alist (magit--ghub-graphql prj magit-github--fetch-pullreqs
                                   `((owner . ,(oref prj owner))
                                     (name  . ,(oref prj name))))
     .data.repository.pullRequests.edges)))

;;; Utilities

(cl-defun magit--ghub-graphql (prj graphql &optional variables
                                   &key silent callback errorback)
  (ghub-graphql graphql variables
                :host      (oref prj apihost)
                :auth      'magit
                :silent    silent
                :callback  callback
                :errorback errorback))

;;; _
(provide 'magit/forge/github)
;;; magit/forge/github.el ends here
