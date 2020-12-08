it('should get names of components', () => {
    cy.visit('/')
        .get('.site-description')
        .should('contain.text', 'Just another WordPress site')
})
