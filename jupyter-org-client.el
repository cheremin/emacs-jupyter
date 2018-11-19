;;; jupyter-org-client.el --- Org integration -*- lexical-binding: t -*-

;; Copyright (C) 2018 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 02 Jun 2018
;; Version: 0.6.0

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;;

;;; Code:

(require 'jupyter-repl)
(require 'ob)
(require 'org-element)

(declare-function org-at-drawer-p "org")
(declare-function org-in-regexp "org" (regexp &optional nlines visually))
(declare-function org-in-src-block-p "org" (&optional inside))
(declare-function org-babel-python-table-or-string "ob-python" (results))
(declare-function org-babel-jupyter-initiate-session "ob-jupyter" (&optional session params))

(defcustom jupyter-org-resource-directory "./.ob-jupyter/"
  "Directory used to store automatically generated image files.
See `jupyter-org-image-file-name'."
  :group 'ob-jupyter
  :type 'string)

(defconst jupyter-org-mime-types '(:text/org
                                   ;; Prioritize images over html
                                   :image/svg+xml :image/jpeg :image/png
                                   :text/html :text/markdown
                                   :text/latex :text/plain)
  "MIME types handled by Jupyter Org.")

(defclass jupyter-org-client (jupyter-repl-client)
  ((block-params
    :initform nil
    :documentation "The parameters of the most recently executed
source code block. Set by `org-babel-execute:jupyter'.")))

(cl-defstruct (jupyter-org-request
               (:include jupyter-request)
               (:constructor nil)
               (:constructor jupyter-org-request))
  result-type
  block-params
  results
  silent
  id-cleared-p
  marker
  async)

;;; Predicates

(defun jupyter-org-file-header-arg-p (req)
  "Determine if the source block of REQ specifies a file header argument."
  (let ((params (jupyter-org-request-block-params req)))
    (member "file" (assq :result-params params))))

;;; `jupyter-kernel-client' interface

(cl-defmethod jupyter-generate-request ((client jupyter-org-client) _msg
                                        &context (major-mode (eql org-mode)))
  "Return a `jupyter-org-request' for the current source code block."
  (let* ((block-params (oref client block-params))
         (result-params (alist-get :result-params block-params)))
    (jupyter-org-request
     :marker (copy-marker org-babel-current-src-block-location)
     :result-type (alist-get :result-type block-params)
     :block-params block-params
     :async (equal (alist-get :async block-params) "yes")
     :silent (car (or (member "none" result-params)
                      (member "silent" result-params))))))

(cl-defmethod jupyter-drop-request ((_client jupyter-org-client)
                                    (req jupyter-org-request))
  (set-marker (jupyter-org-request-marker req) nil))

(cl-defmethod jupyter-handle-stream ((_client jupyter-org-client)
                                     (req jupyter-org-request)
                                     _name
                                     text)
  (jupyter-org--add-result
   req (with-temp-buffer
         (jupyter-with-control-code-handling
          (insert (ansi-color-apply text)))
         (buffer-string))))

(cl-defmethod jupyter-handle-status ((_client jupyter-org-client)
                                     (req jupyter-org-request)
                                     execution-state)
  (when (equal execution-state "idle")
    (message "Code block evaluation complete.")
    (when (jupyter-org-request-async req)
      (jupyter-org--clear-request-id req)
      (run-hooks 'org-babel-after-execute-hook))))

(cl-defmethod jupyter-handle-error ((_client jupyter-org-client)
                                    (req jupyter-org-request)
                                    ename
                                    evalue
                                    traceback)
  (jupyter-with-display-buffer "traceback" 'reset
    (jupyter-insert-ansi-coded-text
     (mapconcat #'identity traceback "\n"))
    (goto-char (line-beginning-position))
    (pop-to-buffer (current-buffer)))
  (jupyter-org--add-result
   req (jupyter-org-scalar (format "%s: %s" ename (ansi-color-apply evalue)))))

(cl-defmethod jupyter-handle-execute-result ((_client jupyter-org-client)
                                             (req jupyter-org-request)
                                             _execution-count
                                             data
                                             metadata)
  (unless (eq (jupyter-org-request-result-type req) 'output)
    (jupyter-org--add-result
     req (jupyter-org-result req data metadata))))

(cl-defmethod jupyter-handle-display-data ((_client jupyter-org-client)
                                           (req jupyter-org-request)
                                           data
                                           metadata
                                           ;; TODO: Add request objects as text
                                           ;; properties of source code blocks
                                           ;; to implement display IDs. Or how
                                           ;; can #+NAME be used as a display
                                           ;; ID?
                                           _transient)
  (jupyter-org--add-result req (jupyter-org-result req data metadata)))

(cl-defmethod jupyter-handle-execute-reply ((client jupyter-org-client)
                                            (_req jupyter-org-request)
                                            _status
                                            execution-count
                                            _user-expressions
                                            payload)
  ;; TODO: Re-use the REPL's handler somehow?
  (oset client execution-count (1+ execution-count))
  (when payload
    (jupyter-repl--handle-payload payload)))


;;; Completions in code blocks

(defvar jupyter-org--src-block-cache nil
  "A list of three elements (SESSION BEG END).
SESSION is the Jupyter session to use for completion requests for
a code block between BEG and END.

BEG and END are the bounds of the source block which made the
most recent completion request.")

(defun jupyter-org--same-src-block-p ()
  (and jupyter-org--src-block-cache
       (cl-destructuring-bind (_ beg end)
           jupyter-org--src-block-cache
         (<= beg (point) end))))

(defun jupyter-org--set-current-src-block ()
  (unless (jupyter-org--same-src-block-p)
    (let* ((el (org-element-at-point))
           (lang (org-element-property :language el)))
      (when (string-prefix-p "jupy-" lang)
        (let* ((info (org-babel-get-src-block-info el))
               (params (nth 2 info))
               (beg (save-excursion
                      (goto-char
                       (org-element-property :begin el))
                      (line-beginning-position 2)))
               (end (save-excursion
                      (goto-char
                       (org-element-property :end el))
                      (let ((pblank (org-element-property :post-blank el)))
                        (line-beginning-position
                         (unless (zerop pblank) (- pblank)))))))
          (unless jupyter-org--src-block-cache
            (setq jupyter-org--src-block-cache
                  (list nil (point-marker) (point-marker)))
            ;; Move the end marker when text is inserted
            (set-marker-insertion-type (nth 2 jupyter-org--src-block-cache) t))
          (setf (nth 0 jupyter-org--src-block-cache) params)
          (cl-callf move-marker (nth 1 jupyter-org--src-block-cache) beg)
          (cl-callf move-marker (nth 2 jupyter-org--src-block-cache) end))))))

(defmacro jupyter-org-when-in-src-block (&rest body)
  "Evaluate BODY when inside a Jupyter source block.
Return the result of BODY when it is evaluated, otherwise nil is
returned."
  (declare (debug (body)))
  `(if (not (org-in-src-block-p 'inside))
       ;; Invalidate cache when going outside of a source block. This way if
       ;; the language of the block changes we don't end up using the cache
       ;; since it is only used for Jupyter blocks.
       (prog1 nil
         (when jupyter-org--src-block-cache
           (set-marker (nth 1 jupyter-org--src-block-cache) nil)
           (set-marker (nth 2 jupyter-org--src-block-cache) nil)
           (setq jupyter-org--src-block-cache nil)))
     (jupyter-org--set-current-src-block)
     (when (jupyter-org--same-src-block-p)
       ,@body)))

(defmacro jupyter-org-with-src-block-client (&rest body)
  "Evaluate BODY with `jupyter-current-client' set to the session's client.
If `point' is not at a Jupyter source block, BODY is not
evaluated and nil is returned. Return the result of BODY when it
is evaluated.

In addition to evaluating BODY with an active Jupyter client set,
the `syntax-table' will be set to that of the REPL buffers."
  (declare (debug (body)))
  `(jupyter-org-when-in-src-block
    (let* ((params (car jupyter-org--src-block-cache))
           (buffer (org-babel-jupyter-initiate-session
                    (alist-get :session params) params))
           (syntax (with-current-buffer buffer (syntax-table)))
           (jupyter-current-client
            (with-current-buffer buffer jupyter-current-client)))
      (with-syntax-table syntax
        ,@body))))

(cl-defmethod jupyter-code-context ((_type (eql inspect))
                                    &context (major-mode org-mode))
  (when (org-in-src-block-p 'inside)
    (jupyter-line-context)))

(cl-defmethod jupyter-code-context ((_type (eql completion))
                                    &context (major-mode org-mode))
  (when (org-in-src-block-p 'inside)
    (jupyter-line-context)))

(defun jupyter-org-completion-at-point ()
  (jupyter-org-with-src-block-client
   (jupyter-completion-at-point)))

(defun jupyter-org-enable-completion ()
  "Enable autocompletion in Jupyter source code blocks."
  (add-hook 'completion-at-point-functions 'jupyter-org-completion-at-point nil t))

(add-hook 'org-mode-hook 'jupyter-org-enable-completion)

;;; Constructing org syntax trees

(defun jupyter-org-export-block (type value)
  "Return an export-block `org-element'.
The block will export TYPE and the contents of the block will be
VALUE."
  (list 'export-block (list :type type
                            :value (org-element-normalize-string value))))

(defun jupyter-org-file-link (path)
  "Return a file link `org-element' that points to PATH."
  ;; A link is an object not an element so :post-blank means number of spaces
  ;; not number of newlines. Wrapping the link in a list ensures that
  ;; `org-element-interpret-data' will insert a newline after inserting the
  ;; link.
  (list (list 'link (list :type "file" :path path)) "\n"))

(defun jupyter-org-src-block (language parameters value &optional switches)
  "Return a src-block `org-element'.
LANGUAGE, PARAMETERS, VALUE, and SWITCHES all have the same
meaning as a src-block `org-element'."
  (declare (indent 2))
  (list 'src-block (list :language language
                         :parameters parameters
                         :switched switches
                         :value value)))

(defun jupyter-org-example-block (value)
  "Return an example-block `org-element' with VALUE."
  (list 'example-block (list :value (org-element-normalize-string value))))

;; From `org-babel-insert-result'
(defun jupyter-org-tabulablep (r)
  ;; Non-nil when result R can be turned into
  ;; a table.
  (and (listp r)
       (null (cdr (last r)))
       (cl-every
        (lambda (e) (or (atom e) (null (cdr (last e)))))
        r)))

(defun jupyter-org-scalar (value)
  "Return a scalar VALUE.
If VALUE is a string, return either a fixed-width `org-element'
or example-block depending on
`org-babel-min-lines-for-block-output'.

If VALUE is a list and can be represented as a table, return an
`org-mode' table as a string.

Otherwise, return VALUE formated as a fixed-width `org-element'."
  (cond
   ((stringp value)
    (if (cl-loop with i = 0 for c across value if (eq c ?\n) do (cl-incf i)
                 thereis (> i org-babel-min-lines-for-block-output))
        (jupyter-org-example-block value)
      (list 'fixed-width (list :value value))))
   ((and (listp value)
         (not (or (memq (car value) org-element-all-objects)
                  (memq (car value) org-element-all-elements)))
         (jupyter-org-tabulablep value))
    ;; From `org-babel-insert-result'
    (with-temp-buffer
      (insert (concat (orgtbl-to-orgtbl
                       (if (cl-every
                            (lambda (e)
                              (or (eq e 'hline) (listp e)))
                            value)
                           value
                         (list value))
                       nil)
                      "\n"))
      (goto-char (point-min))
      (when (org-at-table-p) (org-table-align))
      (let ((table (buffer-string)))
        (prog1 table
          ;; We need a way to distinguish a table string that is easily removed
          ;; from the code block vs a regular string that will need to be
          ;; wrapped in a drawer. See `jupyter-org--append-result'.
          (put-text-property 0 1 'org-table t table)))))
   (t
    (list 'fixed-width (list :value (format "%S" value))))))

(defun jupyter-org-latex-fragment (value)
  "Return a latex-fragment `org-element' consisting of VALUE."
  (list 'latex-fragment (list :value value)))

(defun jupyter-org-latex-environment (value)
  "Return a latex-fragment `org-element' consisting of VALUE."
  (list 'latex-environment (list :value value)))

(defun jupyter-org-results-drawer (&rest results)
  "Return a drawer `org-element' containing RESULTS.
RESULTS can be either strings or other `org-element's. The
returned drawer has a name of \"RESULTS\"."
  ;; Ensure the last element has a newline if it is already a string. This is
  ;; to avoid situations like
  ;;
  ;; :RESULTS:
  ;; foo:END:
  (let ((last (last results)))
    (when (and (stringp (car last))
               (not (zerop (length (car last)))))
      (setcar last (org-element-normalize-string (car last)))))
  (apply #'org-element-set-contents
         (list 'drawer (list :drawer-name "RESULTS"))
         results))

;;; Inserting results

(defun jupyter-org-image-file-name (data ext)
  "Return a file name based on DATA and EXT.
`jupyter-org-resource-directory' is used as the directory name of
the file, the `sha1' hash of DATA is used as the base name, and
EXT is used as the extension."
  (let ((dir (prog1 jupyter-org-resource-directory
               (unless (file-directory-p jupyter-org-resource-directory)
                 (make-directory jupyter-org-resource-directory))))
        (ext (if (= (aref ext 0) ?.) ext
               (concat "." ext))))
    (concat (file-name-as-directory dir) (sha1 data) ext)))

(defun jupyter-org--image-result (mime params data)
  "Return a cons cell (\"file\" . FILENAME).
MIME is the image mimetype, PARAMS is the
`jupyter-org-request-block-params' that caused this result to be
returned and DATA is the image DATA.

If PARAMS contains a :file key, it is used as the FILENAME.
Otherwise a file name is created, see
`jupyter-org-image-file-name'. Note, when PARAMS contains a :file
key any existing file with the file name will be overwritten when
writing the image data. This is not the case when a new file name
is created."
  (let* ((overwrite (not (null (alist-get :file params))))
         (base64-encoded (memq mime '(:image/png :image/jpeg)))
         (file (or (alist-get :file params)
                   (jupyter-org-image-file-name
                    data (cl-case mime
                           (:image/png "png")
                           (:image/jpeg "jpg")
                           (:image/svg+xml "svg"))))))
    (when (or overwrite (not (file-exists-p file)))
      (let ((buffer-file-coding-system
             (if base64-encoded 'binary
               buffer-file-coding-system))
            (require-final-newline nil))
        (with-temp-file file
          (insert data)
          (when base64-encoded
            (base64-decode-region (point-min) (point-max))))))
    (jupyter-org-file-link file)))

(cl-defmethod jupyter-org-result ((req jupyter-org-request) data &optional metadata)
  "For REQ, return the rendered DATA.
DATA is a plist, (:mimetype1 value1 ...), containing the
different representations of a result returned by a kernel.

METADATA is the metadata plist used to render DATA with, as
returned by the Jupyter kernel. This plist typically contains
information such as the size of an image to be rendered. The
metadata plist is currently unused.

Using the `jupyter-org-request-block-params' of REQ, loop over
the MIME types in `jupyter-org-mime-types' calling

    (jupyter-org-result MIME PARAMS DATA METADATA)

for each MIME type. Return the result of the first iteration in
which the above call returns a non-nil value. PARAMS is the REQ's
`jupyter-org-request-block-params', DATA and METADATA are the
data and metadata of the current MIME type."
  (cl-assert data json-plist)
  (let* ((params (jupyter-org-request-block-params req)))
    (or (jupyter-loop-over-mime
            jupyter-org-mime-types mime data metadata
          (jupyter-org-result mime params data metadata))
        (prog1 nil
          (warn "No valid mimetype found %s"
                (cl-loop for (k _v) on data by #'cddr collect k))))))

(cl-defgeneric jupyter-org-result (_mime _params _data &optional _metadata)
  "Return an `org-element' representing a result.
Either a string or an `org-element' is a valid return value of
this method. The former will be inserted as is, while the latter
will be inserted by calling `org-element-interpret-data' first.

The returned result should be a representation of a MIME type
whose value is DATA.

DATA is the data representing the MIME type and METADATA is any
associated metadata associated with the MIME DATA.

As an example, if DATA only contains the mimetype
`:text/markdown', then the returned results is

    (jupyter-org-export-block \"markdown\" data)"
  (ignore))

(cl-defmethod jupyter-org-result ((_mime (eql :application/vnd.jupyter.widget-view+json))
                                  _params _data &optional _metadata)
  ;; TODO: Clickable text to open up a browser
  (jupyter-org-scalar "Widget"))

(cl-defmethod jupyter-org-result ((_mime (eql :text/org)) _params data
                                  &optional _metadata)
  data)

(cl-defmethod jupyter-org-result ((mime (eql :image/png)) params data
                                  &optional _metadata)
  ;; TODO: Add ATTR_ORG with the width and height. This can be done for example
  ;; by adding a function to `org-babel-after-execute-hook'.
  (jupyter-org--image-result mime params data))

(cl-defmethod jupyter-org-result ((mime (eql :image/jpeg)) params data
                                  &optional _metadata)
  (jupyter-org--image-result mime params data))

(cl-defmethod jupyter-org-result ((mime (eql :image/svg+xml)) params data
                                  &optional _metadata)
  (jupyter-org--image-result mime params data))

(cl-defmethod jupyter-org-result ((_mime (eql :text/markdown)) _params data
                                  &optional _metadata)
  (jupyter-org-export-block "markdown" data))

(cl-defmethod jupyter-org-result ((_mime (eql :text/latex)) params data
                                  &optional _metadata)
  (if (member "raw" (alist-get :result-params params))
      (with-temp-buffer
        (save-excursion (insert data))
        (or (save-excursion (org-element-latex-fragment-parser))
            (let ((env (ignore-errors
                         (org-element-latex-environment-parser
                          (point-max) nil))))
              (if (eq (org-element-type env) 'latex-environment) env
                (jupyter-org-latex-environment
                 (concat "\
\\begin{minipage}{\\textwidth}
\\begin{flushright}\n" data "\n\\end{flushright}
\\end{minipage}\n"))))))
    (jupyter-org-export-block "latex" data)))

(cl-defmethod jupyter-org-result ((_mime (eql :text/html)) _params data
                                  &optional _metadata)
  (jupyter-org-export-block "html" data))

;; NOTE: The order of :around methods is that the more specialized wraps the
;; more general, this makes sense since it is how the primary methods work as
;; well.
;;
;; Using an :around method to attempt to guarantee that this is called as the
;; outer most method. Kernel languages should extend the primary method.
(cl-defmethod jupyter-org-result :around ((_mime (eql :text/plain)) &rest _)
  "Do some final transformations of the result.
Call the next method, if it returns \"scalar\" results, return a
new \"scalar\" result with the result of calling
`org-babel-script-escape' on the old result."
  (let ((result (cl-call-next-method)))
    (jupyter-org-scalar
     (cond
      ((stringp result) (org-babel-script-escape result))
      (t result)))))

(cl-defmethod jupyter-org-result ((_mime (eql :text/plain)) _params data
                                  &optional _metadata)
  data)

(defun jupyter-org--clear-request-id (req)
  "Delete the ID of REQ in the `org-mode' buffer if present."
  (save-excursion
    (when (search-forward (jupyter-request-id req) nil t)
      (delete-region (line-beginning-position)
                     (1+ (line-end-position)))
      (setf (jupyter-org-request-id-cleared-p req) t))))

(defun jupyter-org--element-end-preserve-blanks (el)
  (let ((end (org-element-property :end el))
        (post (or (org-element-property :post-blank el) 0)))
    (save-excursion
      (goto-char end)
      (forward-line (- post))
      (line-beginning-position))))

(defun jupyter-org--append-result (req result)
  (org-with-point-at (jupyter-org-request-marker req)
    (let ((result-beg (org-babel-where-is-src-block-result 'insert))
          (inhibit-redisplay (not debug-on-error)))
      (goto-char result-beg)
      (unless (jupyter-org-request-id-cleared-p req)
        (jupyter-org--clear-request-id req))
      (if (org-at-drawer-p)
          (let* ((el (org-element-at-point))
                 (content-end (org-element-property :contents-end el))
                 (pos (or content-end
                          (jupyter-org--element-end-preserve-blanks el))))
            (goto-char pos))
        ;; Only wrap the result in a drawer when its a string that would be
        ;; hard for `org' to remove when replacing the results or if the result
        ;; is the first result. If there is already a result, remove it and
        ;; place it as the first item in a drawer and the current result being
        ;; inserted as the second. Then insert the drawer.
        (let* ((context (org-element-context))
               (first-result (eq (org-element-type context) 'keyword)))
          (cond
           ((and
             first-result
             ;; When this is the first result, distinguished by there only
             ;; being a #+RESULTS keyword line, then results are wrapped in a
             ;; drawer only if: (1) The results are a string, but not a string
             ;; representing an org table or (2) The results cannot be removed
             ;; by `org-babel-remove-result'.
             (if (stringp result)
                 ;; Org tables are returned as strings by this time. So we need
                 ;; something to distinguish them from regular strings. See
                 ;; `jupyter-org-scalar'.
                 (get-text-property 0 'org-table result)
               (memq (org-element-type result)
                     ;; No need to wrap these types in a drawer since
                     ;; `org-babel-remove-result' will be able to remove
                     ;; them. Everything else we will have to.
                     '(example-block
                       export-block fixed-width item
                       plain-list src-block table)))))
           (t
            (and (stringp result) (setq result (org-element-normalize-string result)))
            (if first-result
                ;; If this is the first result and it is not able to be placed
                ;; in the buffer without being wrapped in a drawer, wrap it.
                (setq result (jupyter-org-results-drawer result))
              ;; Otherwise there already exists a result in the buffer that
              ;; needs to be wrapped along with the new result.
              (setq result (jupyter-org-results-drawer context result))
              ;; Remove these properties since `org-element-interpret-data'
              ;; uses them?
              ;; :post-affiliated is used here as opposed to :begin so that we
              ;; don't remove the #+RESULTS line which is an affiliated keyword
              (delete-region (org-element-property :post-affiliated context)
                             (jupyter-org--element-end-preserve-blanks context))
              ;; Ensure that a #+RESULTS: line is not prepended to context when
              ;; calling `org-element-interpret-data'
              (org-element-put-property context :results nil)
              ;; Ensure there is no post-blank since
              ;; `org-element-interpret-data' already normalizes the string
              (org-element-put-property context :post-blank nil))))))
      (when (= result-beg (point))
        (forward-line))
      (insert (org-element-interpret-data result)))))

(defun jupyter-org--add-result (req result)
  "For REQ, add RESULT.
REQ is a `jupyter-org-request' and if the request is a
synchronous request, RESULT will be pushed to the list of results
in the request's results slot or appended to the buffer if REQ is
already complete. Otherwise, when the request is asynchronous,
RESULT is inserted at the location of the code block for the
request."
  (if (jupyter-org-request-silent req)
      (unless (equal (jupyter-org-request-silent req) "none")
        (message "%s" (org-element-interpret-data result)))
    (if (or (jupyter-org-request-async req)
            (jupyter-request-idle-received-p req))
        (jupyter-org--append-result req result)
      (push result (jupyter-org-request-results req)))))

(defun jupyter-org-insert-async-id (req)
  "Insert the ID of REQ.
Meant to be used as the return value of
`org-babel-execute:jupyter'."
  (prog1 nil
    (advice-add 'message :override #'ignore)
    (setq org-babel-after-execute-hook
          (let ((hook org-babel-after-execute-hook))
            (lambda ()
              (advice-remove 'message #'ignore)
              (unwind-protect
                  (jupyter-org--add-result
                   req (jupyter-org-scalar (jupyter-org-request-id req)))
                (setq org-babel-after-execute-hook hook)
                (run-hooks 'org-babel-after-execute-hook)))))))

(defun jupyter-org-insert-sync-results (req)
  "Insert the results of REQ.
Meant to be used as the return value of `org-babel-execute:jupyter'."
  (prog1 nil
    (advice-add 'message :override #'ignore)
    (setq org-babel-after-execute-hook
          (let ((hook org-babel-after-execute-hook))
            (lambda ()
              (advice-remove 'message #'ignore)
              (unwind-protect
                  (cl-loop
                   for result in (nreverse (jupyter-org-request-results req))
                   do (jupyter-org--add-result req result))
                (setq org-babel-after-execute-hook hook)
                (run-hooks 'org-babel-after-execute-hook)))))))

(provide 'jupyter-org-client)

;;; jupyter-org-client.el ends here
