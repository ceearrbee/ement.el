;;; ement-search.el --- Full-text search for Ement  -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Free Software Foundation, Inc.

;; Author: Adam Porter <adam@alphapapa.net>
;; Maintainer: Adam Porter <adam@alphapapa.net>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides full-text search across Matrix rooms using the
;; server-side search API.

;;; Code:

;;;; Requirements

(require 'json)

(require 'ement)
(require 'ement-lib)
(require 'ement-room)

;;;; Variables

(defvar ement-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ement-search-goto-event)
    (define-key map (kbd "+") #'ement-search-next-batch)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "q") #'quit-window)
    map))

(defvar-local ement-search-etc nil
  "Alist storing search state in `ement-search' buffers.")

;;;; Customization

(defgroup ement-search nil
  "Options for full-text search."
  :group 'ement)

;;;; Mode

(define-derived-mode ement-search-mode special-mode "Ement-Search"
  "Mode for Ement search results."
  :group 'ement-search
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (when-let* ((query (alist-get 'query ement-search-etc)))
                  (ement-search query (alist-get 'session ement-search-etc))))))

;;;; Commands

(defun ement-search (query session)
  "Search for QUERY across rooms on SESSION.
Results are displayed in a buffer."
  (interactive (list (read-string "Search Matrix: ")
                     (ement-complete-session)))
  (when (string-empty-p query)
    (user-error "Search query cannot be empty"))
  (message "Searching for: %s..." query)
  (let ((data (json-encode
               (ement-alist
                "search_categories"
                (ement-alist
                 "room_events"
                 (ement-alist "search_term" query
                              "order_by" "recent"))))))
    (ement-api session "search" :method 'post :data data
      :version "v3"
      :then (lambda (response)
              (ement-search--display-results response query session))
      :else (lambda (err)
              (message "Search error: %S" err)))))

(defun ement-search-goto-event ()
  "Go to the event at point in its room buffer."
  (interactive)
  (let ((event-data (get-text-property (point) 'ement-search-event)))
    (unless event-data
      (user-error "No event at point"))
    (pcase-let* (((map room-id event-id) event-data)
                 ((map session) ement-search-etc)
                 (room (cl-find room-id (ement-session-rooms session)
                                :key #'ement-room-id :test #'equal)))
      (if room
          (progn
            (ement-view-room room session)
            (when-let ((event (gethash event-id (ement-session-events session))))
              (ement-room-goto-event event)))
        (message "Room not found: %s" room-id)))))

(defun ement-search-next-batch ()
  "Fetch the next batch of search results."
  (interactive)
  (if-let* ((next-batch (alist-get 'next-batch ement-search-etc)))
      (let* ((query (alist-get 'query ement-search-etc))
             (session (alist-get 'session ement-search-etc))
             (data (json-encode
                    (ement-alist
                     "search_categories"
                     (ement-alist
                      "room_events"
                      (ement-alist "search_term" query
                                   "order_by" "recent"))))))
        (message "Fetching more results...")
        (ement-api session (format "search?next_batch=%s"
                                   (url-hexify-string next-batch))
          :method 'post :data data :version "v3"
          :then (lambda (response)
                  (ement-search--append-results response))
          :else (lambda (err)
                  (message "Search error: %S" err))))
    (message "No more results.")))

;;;; Functions

(defun ement-search--display-results (response query session)
  "Display search RESPONSE for QUERY on SESSION."
  (pcase-let* (((map ('search_categories
                       (map ('room_events
                             (map ('results results)
                                  ('count count)
                                  ('next_batch next-batch))))))
                response)
               (buffer-name "*Ement Search*"))
    (with-current-buffer (get-buffer-create buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ement-search-mode)
        (setf ement-search-etc (ement-alist 'query query
                                            'session session
                                            'next-batch next-batch))
        (setf header-line-format
              (format "Search: \"%s\" (%d results%s)"
                      query (or count 0)
                      (if next-batch " [press + for more]" "")))
        (ement-search--insert-results results session)
        (goto-char (point-min))))
    (pop-to-buffer buffer-name)))

(defun ement-search--append-results (response)
  "Append more search results from RESPONSE."
  (pcase-let* (((map ('search_categories
                       (map ('room_events
                             (map ('results results)
                                  ('next_batch next-batch))))))
                response))
    (setf (alist-get 'next-batch ement-search-etc) next-batch)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (ement-search--insert-results results (alist-get 'session ement-search-etc)))
    (setf header-line-format
          (format "Search: \"%s\" (%s results%s)"
                  (alist-get 'query ement-search-etc)
                  "many"
                  (if next-batch " [press + for more]" "")))))

(defun ement-search--insert-results (results session)
  "Insert RESULTS into the current buffer for SESSION."
  (cl-loop for result across results
           do (pcase-let* (((map ('result
                                   (map ('event_id event-id)
                                        ('sender sender-id)
                                        ('room_id room-id)
                                        ('origin_server_ts ts)
                                        ('content (map body)))))
                            result)
                           (room (cl-find room-id (ement-session-rooms session)
                                          :key #'ement-room-id :test #'equal))
                           (room-name (if room
                                          (or (ement-room-display-name room)
                                              (ement--room-display-name room))
                                        room-id))
                           (user (gethash sender-id ement-users))
                           (sender-name (if user
                                            (or (ement-user-displayname user) sender-id)
                                          sender-id))
                           (time-str (format-time-string "%Y-%m-%d %H:%M"
                                                         (/ ts 1000))))
                (when body
                  (insert
                   (propertize
                    (concat
                     (propertize time-str 'face 'ement-room-timestamp)
                     " "
                     (propertize room-name 'face 'ement-room-name)
                     " "
                     (propertize sender-name 'face 'ement-room-user)
                     ": "
                     (replace-regexp-in-string "\n" " " body)
                     "\n")
                    'ement-search-event (ement-alist 'room-id room-id
                                                     'event-id event-id)))))))

(provide 'ement-search)

;;; ement-search.el ends here
